#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Runs the app's acceptance tests against the deployed environment, then reloads its test data.

.DESCRIPTION
    Step "Acceptance tests" of the Octopus project <slug>-<deployable>, in the environments whose system.json entry has
    "acceptanceTests": true (the first environment: the first time a version runs on its real Azure resources);
    octopus/projects.tf inlines this file. It runs in the custom test-runner image (Playwright plus the .NET 10 SDK,
    images/test-runner; Chromium and pwsh included) on the release's acceptance-test package:
      1. The suite's Chromium when the image lacks it (the suite's Playwright is newer than the image's), with the
         image's own pwsh; then the image's .NET 10 SDK when present, otherwise a temporary install with retries
         (fallback only: the worker image is meant to carry the SDK so deploys do not download it).
      2. The suite in remote mode (no local server, no Worker: those tests skip themselves) against the app's URL,
         with the database connection from "Open test database": every test, or only the tests of the deployable's
         acceptanceTestsFilter in system.json (AcceptanceTests.Filter, a dotnet test filter such as
         TestCategory=Smoke; the app's pull requests run the full suite). The suite starts by loading its own data
         (ZDataLoader). Parallel test workers: AcceptanceTests.Workers, or 0 for 1.5 per core, capped by memory
         (0.5 GB per browser) and at 16; a worker starts a browser only for a test, so a small set needs no other
         sizing. The run reports how many tests actually ran at once.
      3. Always, even after failures: ZDataLoader once more, so the environment is left with good test data.
    A test that runs for more than five minutes is a hung test: the test platform then ends the run and names the
    test (--blame-hang-timeout), so a hang fails the deployment in minutes and does not hold the environment's queue.
    The test results (TRX) are attached to the deployment as artifacts. A failed test fails the deployment, which
    keeps the release from being promoted; the version stays pinned, because it is what runs. A run in which no test
    ran fails too: a filter that matches nothing, or tests that all skip themselves, prove nothing.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

function Test-DotNetSdkListHas10 {
    # True when --list-sdks output already names a 10.x SDK (the baked worker image).
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]] $SdkList)
    return @($SdkList | Where-Object { $_ -match '^\s*10\.' }).Count -gt 0
}

function Install-DotNet10Sdk {
    # Fallback when the worker image has no SDK 10: download with retries and alternate official script URLs.
    param([Parameter(Mandatory)][string] $InstallDir)
    $installer = Join-Path ([IO.Path]::GetTempPath()) 'dotnet-install.sh'
    $installerUrls = @('https://dot.net/v1/dotnet-install.sh', 'https://builds.dotnet.microsoft.com/dotnet/scripts/v1/dotnet-install.sh')
    $maxAttempts = 5
    $installed = $false
    for ($attempt = 1; $attempt -le $maxAttempts -and -not $installed; $attempt++) {
        $url = $installerUrls[($attempt - 1) % $installerUrls.Count]
        try {
            Invoke-WebRequest -Uri $url -OutFile $installer -TimeoutSec 120
            bash $installer --channel 10.0 --install-dir $InstallDir --no-path | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "dotnet-install.sh exited with $LASTEXITCODE" }
            $installed = $true
        }
        catch {
            Write-Warning "dotnet SDK install attempt $attempt of $maxAttempts from $url failed: $($_.Exception.Message)"
            if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds (5 * $attempt) }
        }
    }
    if (-not $installed) { throw "The .NET 10 SDK install failed after $maxAttempts attempts." }
}

$package = [string] $OctopusParameters['Octopus.Action.Package[tests].ExtractedPath']
$testAssembly = Join-Path $package ([string] $OctopusParameters['AcceptanceTests.Assembly'])
$loaderAssembly = Join-Path $package ([string] $OctopusParameters['DataLoader.Assembly'])
$baseUrl = [string] $OctopusParameters['Octopus.Action[Open test database].Output.ApplicationBaseUrl']
$connectionString = [string] $OctopusParameters['Octopus.Action[Open test database].Output.SqlConnectionString']
$requestedWorkers = [int] $OctopusParameters['AcceptanceTests.Workers']
$filter = ([string] $OctopusParameters['AcceptanceTests.Filter']).Trim()
$selection = if ($filter) { @('--filter', $filter) } else { @() }
$scope = if ($filter) { "filter $filter" } else { 'full suite' }
$results = Join-Path (Get-Location) 'results'
New-Item -ItemType Directory -Path $results -Force | Out-Null

$clock = [Diagnostics.Stopwatch]::StartNew()
# The suite's Chromium before any DOTNET_ROOT change: the suite's playwright.ps1 runs in a child pwsh that may be a
# framework-dependent .NET app and cannot start once DOTNET_ROOT points only at a temporary .NET 10 folder (cmdemo1,
# Playwright 1.61 on the 1.54 image, 2026-10-26). Zip extraction drops the execute bit of Playwright's Node driver. A
# headless run uses the headless shell since Playwright 1.49: both are checked, and "install chromium" brings both.
Get-ChildItem -LiteralPath (Join-Path $package '.playwright') -Recurse -File -Force -Filter 'node' | ForEach-Object { chmod +x $_.FullName }
$browsers = @((Get-Content -LiteralPath (Join-Path $package '.playwright' 'package' 'browsers.json') -Raw | ConvertFrom-Json).browsers)
$revision = @($browsers | Where-Object { $_.name -eq 'chromium' })[0].revision
$wanted = @("chromium-$revision") + @($browsers | Where-Object { $_.name -eq 'chromium-headless-shell' } | ForEach-Object { "chromium_headless_shell-$($_.revision)" })
$absent = @($wanted | Where-Object { -not (Test-Path -LiteralPath (Join-Path ([string] $env:PLAYWRIGHT_BROWSERS_PATH) $_)) })
if ($absent.Count -gt 0) {
    Write-Warning "The image has no $($absent -join ', ') (the suite's Playwright version changed): installing Chromium."
    pwsh -NoProfile -File (Join-Path $package 'playwright.ps1') install chromium
    Write-Host "Chromium $revision installed in $([int] $clock.Elapsed.TotalSeconds) s"
}

$clock.Restart()
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_NOLOGO = '1'
$sdkList = @()
$dotnetCommand = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnetCommand) {
    $PSNativeCommandUseErrorActionPreference = $false
    $sdkList = @(& $dotnetCommand.Source --list-sdks 2>$null)
    $PSNativeCommandUseErrorActionPreference = $true
}
if (Test-DotNetSdkListHas10 -SdkList $sdkList) {
    Write-Host ".NET $(dotnet --version) SDK (image) in $([int] $clock.Elapsed.TotalSeconds) s"
}
else {
    $dotnetRoot = Join-Path ([IO.Path]::GetTempPath()) 'dotnet10'
    Install-DotNet10Sdk -InstallDir $dotnetRoot
    $env:DOTNET_ROOT = $dotnetRoot
    $env:PATH = "${dotnetRoot}:$env:PATH"
    Write-Host ".NET $(dotnet --version) SDK (fallback install) in $([int] $clock.Elapsed.TotalSeconds) s"
}

# Before the try: the data reload in finally needs the deployed environment's database, whatever failed first
# (without it the loader falls back to SQLite and fails on its own, which hides the cause).
$env:ApplicationBaseUrl = $baseUrl
$env:ConnectionStrings__SqlConnectionString = $connectionString
$env:StartLocalServer = 'false'
$env:StartWorker = 'false'
$env:HeadlessTestBrowser = 'true'
$env:SkipScreenshotsForSpeed = 'true'
$env:TEST_INPUT_DELAY_MS = [string] $OctopusParameters['AcceptanceTests.InputDelayMs']

$testsExit = 1
$loadExit = 1
$executed = 0
try {
    $cores = [Environment]::ProcessorCount
    $memoryGb = ([long] ((Get-Content -LiteralPath '/proc/meminfo' | Select-String -Pattern '^MemTotal:\s+(\d+)').Matches[0].Groups[1].Value)) / 1MB
    $automatic = [Math]::Max(2, [Math]::Min(16, [Math]::Min([Math]::Floor($cores * 1.5), [Math]::Floor(($memoryGb - 1) / 0.5))))
    $workers = if ($requestedWorkers -gt 0) { $requestedWorkers } else { [int] $automatic }
    Write-Highlight "Acceptance tests ($scope): $workers parallel workers ($cores cores, $([Math]::Round($memoryGb, 1)) GB) against $baseUrl"

    function Get-TrxSummary {
        # Counts and the parallelism the run reached: the sum of test durations over the wall time of the tests.
        # A run without tests has no Results element, which strict mode would not let the dotted path read.
        param([Parameter(Mandatory)] [string] $Path)
        [xml] $trx = Get-Content -LiteralPath $Path -Raw
        $counters = $trx.TestRun.ResultSummary.Counters
        $tests = @($trx.TestRun.SelectNodes("*[local-name()='Results']/*[local-name()='UnitTestResult']"))
        $parallelism = 0
        if ($tests.Count -gt 0) {
            $busy = ($tests | ForEach-Object { [TimeSpan]::Parse($_.duration).TotalSeconds } | Measure-Object -Sum).Sum
            $wall = (([datetimeoffset[]] @($tests.endTime) | Measure-Object -Maximum).Maximum - ([datetimeoffset[]] @($tests.startTime) | Measure-Object -Minimum).Minimum).TotalSeconds
            if ($wall -gt 0) { $parallelism = [Math]::Round($busy / $wall, 2) }
        }
        return [pscustomobject] @{
            Executed = [int] $counters.executed
            Text     = "$($counters.passed) passed, $($counters.failed) failed, $([int] $counters.total - [int] $counters.executed) not run; effective parallelism $parallelism"
        }
    }

    $clock.Restart()
    $PSNativeCommandUseErrorActionPreference = $false
    dotnet test $testAssembly @selection --settings (Join-Path $package 'AcceptanceTests.runsettings') `
        --logger 'trx;LogFileName=acceptance.trx' --logger 'console;verbosity=minimal' --results-directory $results `
        --blame-hang-timeout 5m --blame-hang-dump-type none `
        -- "NUnit.NumberOfTestWorkers=$workers"
    $testsExit = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    $acceptanceTrx = Join-Path $results 'acceptance.trx'
    if (Test-Path -LiteralPath $acceptanceTrx) {
        $summary = Get-TrxSummary -Path $acceptanceTrx
        $executed = $summary.Executed
        Write-Highlight "Acceptance tests in $([int] $clock.Elapsed.TotalSeconds) s: $($summary.Text)"
        New-OctopusArtifact -Path $acceptanceTrx -Name "acceptance-tests-$($OctopusParameters['Octopus.Environment.Name'])-$($OctopusParameters['Octopus.Release.Number']).trx"
    }
}
finally {
    $clock.Restart()
    $PSNativeCommandUseErrorActionPreference = $false
    dotnet test $loaderAssembly --filter 'FullyQualifiedName~ZDataLoader' `
        --logger 'trx;LogFileName=load-data.trx' --logger 'console;verbosity=minimal' --results-directory $results `
        --blame-hang-timeout 5m --blame-hang-dump-type none
    $loadExit = $LASTEXITCODE
    $PSNativeCommandUseErrorActionPreference = $true
    Write-Host "Test data reloaded (ZDataLoader) in $([int] $clock.Elapsed.TotalSeconds) s, exit code $loadExit"
}

if ($loadExit -ne 0) {
    Fail-Step 'ZDataLoader could not reload the test data (above).'
}
if ($testsExit -ne 0) {
    Fail-Step "Acceptance tests failed against $baseUrl (results attached as an artifact; a test that ran for more than five minutes ends the run and is named above); the test data was reloaded."
}
if ($executed -eq 0) {
    Fail-Step "No acceptance test ran against $baseUrl ($scope): none matched, or every one skipped itself, and a run that tests nothing must not pass; the test data was reloaded."
}
Write-Highlight "Acceptance tests passed; the test data was reloaded."

# Said as an exit code: Octopus ends a step with the exit code of the last program its script ran, which may be one
# whose refusal was expected and handled (a dormant system's resources that are gone: cmdemo2, 2026-10-15).
exit 0

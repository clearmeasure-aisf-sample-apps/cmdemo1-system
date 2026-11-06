#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Tests the cmdemo1-ui feature-toggle planner without Octopus.

.EXAMPLE
    pwsh -NoProfile -File scripts/test-ui-feature-toggles.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'ensure-ui-feature-toggles.ps1') -LoadOnly

$failures = 0
function Test-Case([string] $Name, $Actual, $Expected) {
    $actualJson = ConvertTo-Json -InputObject @($Actual) -Compress -Depth 6
    $expectedJson = ConvertTo-Json -InputObject @($Expected) -Compress -Depth 6
    if ($actualJson -ceq $expectedJson) { Write-Host "PASS $Name" }
    else { Write-Host "FAIL ${Name}: expected $expectedJson, got $actualJson"; $script:failures++ }
}

$ids = @{ tdd = 'Environments-1'; uat = 'Environments-2'; prod = 'Environments-3' }
$building = (Get-UiFeatureToggleSpecs)[0]
$vendor = (Get-UiFeatureToggleSpecs)[1]

Test-Case 'defaults' @(Get-UiFeatureToggleDefaults).tdd, (Get-UiFeatureToggleDefaults).uat, (Get-UiFeatureToggleDefaults).prod @($true, $false, $false)
Test-Case 'names' @($building.Name, $vendor.Name) @('BuildingManagement', 'VendorManagement')
Test-Case 'slugs match names' @($building.Slug, $vendor.Slug) @($building.Name, $vendor.Name)
foreach ($spec in @(Get-UiFeatureToggleSpecs)) {
    Test-Case "$($spec.Name) description length" (($spec.Description.Length -gt 0) -and ($spec.Description.Length -le 1000)) $true
}

$create = Get-UiFeatureTogglePlan -Spec $building -Current $null -EnvironmentIds $ids -Mode Ensure
Test-Case 'create action' $create.Action 'create'
Test-Case 'create default off' @($create.DefaultIsEnabled, $create.ChangeDefault) @($false, $true)
Test-Case 'create tdd on' (ConvertTo-Boolean ($create.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-1' }).IsEnabled) $true
Test-Case 'create uat off' (ConvertTo-Boolean ($create.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $false
Test-Case 'create prod off' (ConvertTo-Boolean ($create.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-3' }).IsEnabled) $false

$json = ConvertTo-OctopusJson @{ Environments = $create.Environments }
Test-Case 'json environments array' ($json -match '"Environments":\[') $true
Test-Case 'json one on' ([regex]::Matches($json, '"IsEnabled":true').Count) 1
Test-Case 'json two off' ([regex]::Matches($json, '"IsEnabled":false').Count) 2
Test-Case 'json empty phases' ([regex]::Matches($json, '"Phases":\[\]').Count) 3
Test-Case 'json has no api key' ($json -match 'API-') $false
$createBody = ConvertTo-OctopusJson (New-FeatureToggleBody 'Projects-981' 'Spaces-355' $building $create $null)
Test-Case 'create body name' $createBody.Contains('"Name":"BuildingManagement"') $true
Test-Case 'create body project' $createBody.Contains('"ProjectId":"Projects-981"') $true
Test-Case 'create body space' $createBody.Contains('"SpaceId":"Spaces-355"') $true
Test-Case 'create body environments array' $createBody.Contains('"Environments":[') $true
Test-Case 'create body environment id' $createBody.Contains('"DeploymentEnvironmentId":"Environments-1"') $true
Test-Case 'create body omits slug' $createBody.Contains('"Slug"') $false
Test-Case 'create body omits default' $createBody.Contains('"DefaultIsEnabled"') $false
Test-Case 'create body omits phases' $createBody.Contains('"Phases"') $false

$current = [pscustomobject]@{
    Name             = 'BuildingManagement'
    Slug             = 'BuildingManagement'
    Description      = 'operator text'
    DefaultIsEnabled = $false
    Environments     = @(
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-1'; IsEnabled = $true; Phases = @() }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-2'; IsEnabled = $true; Phases = @([pscustomobject]@{ Name = 'staff' }); RolloutPercentage = 10 }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-3'; IsEnabled = $false; Phases = @() }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-9'; IsEnabled = $true; Phases = @() }
    )
}
$kept = Get-UiFeatureTogglePlan -Spec $building -Current $current -EnvironmentIds $ids -Mode Ensure
Test-Case 'flip kept' $kept.Action 'none'
Test-Case 'description kept' $kept.Description 'operator text'

$missingProd = [pscustomobject]@{
    Name             = 'BuildingManagement'
    Slug             = 'BuildingManagement'
    Description      = 'operator text'
    DefaultIsEnabled = $true
    Environments     = @(
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-1'; IsEnabled = $true; Phases = @() }
        [pscustomobject]@{ DeploymentEnvironmentId = 'Environments-2'; IsEnabled = $true; Phases = @() }
    )
}
$added = Get-UiFeatureTogglePlan -Spec $building -Current $missingProd -EnvironmentIds $ids -Mode Ensure
Test-Case 'missing prod is an update' $added.Action 'update'
Test-Case 'missing prod stays off' (ConvertTo-Boolean ($added.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-3' }).IsEnabled) $false
Test-Case 'ensure does not reset uat' (ConvertTo-Boolean ($added.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $true
Test-Case 'ensure does not clear a default that is on' $added.DefaultIsEnabled $true

$reset = Get-UiFeatureTogglePlan -Spec $building -Current $current -EnvironmentIds $ids -Mode ResetDefaults
Test-Case 'reset updates' $reset.Action 'update'
Test-Case 'reset uat off' (ConvertTo-Boolean ($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $false
Test-Case 'reset keeps the extra environment' (ConvertTo-Boolean ($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-9' }).IsEnabled) $true
Test-Case 'reset keeps the phase' @(($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).Phases).Count 1
Test-Case 'reset keeps the phase name' (($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).Phases | Select-Object -First 1).Name 'staff'
$oneList = [System.Collections.Generic.List[object]]::new()
$oneList.Add(($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }))
$oneEnvironment = ConvertTo-OctopusJson @{ Environments = $oneList }
Test-Case 'one environment stays an array' ($oneEnvironment -match '"Environments":\[') $true
Test-Case 'one phase stays an array' ($oneEnvironment -match '"Phases":\[\{') $true
Test-Case 'reset keeps rollout' ($reset.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).RolloutPercentage 10
Test-Case 'reset leaves a default that is already off' @($reset.DefaultIsEnabled, $reset.ChangeDefault) @($false, $false)
$defaultOn = [pscustomobject]@{
    Name             = 'BuildingManagement'
    Slug             = 'BuildingManagement'
    Description      = 'operator text'
    DefaultIsEnabled = $true
    Environments     = $current.Environments
}
$resetDefault = Get-UiFeatureTogglePlan -Spec $building -Current $defaultOn -EnvironmentIds $ids -Mode ResetDefaults
Test-Case 'reset turns a default off' @($resetDefault.DefaultIsEnabled, $resetDefault.ChangeDefault) @($false, $true)
$modifyJson = ConvertTo-OctopusJson (New-FeatureToggleBody 'Projects-981' 'Spaces-355' $building $reset $current)
Test-Case 'modify keeps rollout' $modifyJson.Contains('"RolloutPercentage":10') $true
Test-Case 'modify omits phases' $modifyJson.Contains('"Phases"') $false
Test-Case 'modify default off' $modifyJson.Contains('"DefaultIsEnabled":false') $true

$set = Get-UiFeatureTogglePlan -Spec $vendor -Current $current -EnvironmentIds $ids -Mode Set -EnvironmentName prod -EnvironmentEnabled $true
Test-Case 'set prod on' (ConvertTo-Boolean ($set.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-3' }).IsEnabled) $true
Test-Case 'set leaves uat' (ConvertTo-Boolean ($set.Environments | Where-Object { $_.DeploymentEnvironmentId -eq 'Environments-2' }).IsEnabled) $true
$same = Get-UiFeatureTogglePlan -Spec $vendor -Current $current -EnvironmentIds $ids -Mode Set -EnvironmentName prod -EnvironmentEnabled $false
Test-Case 'set already off is none' $same.Action 'none'

$unknown = $false
try { Get-UiFeatureTogglePlan -Spec $building -Current $null -EnvironmentIds $ids -Mode Set -EnvironmentName staging -EnvironmentEnabled $true } catch { $unknown = $true }
Test-Case 'unknown environment refused' $unknown $true

$chosen = @(Select-UiFeatureToggleSpecs 'Set' 'VendorManagement')
Test-Case 'set selects one' @($chosen.Count, $chosen[0].Name) @(1, 'VendorManagement')
Test-Case 'ensure selects both' @(Select-UiFeatureToggleSpecs 'Ensure' '').Count 2

$offline = @(Get-OfflineEnsurePlans)
Test-Case 'offline create count' $offline.Count 2
Test-Case 'offline second name' $offline[1].Name 'VendorManagement'

$repoSystem = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'system.json') -Raw | ConvertFrom-Json
Assert-UiFeatureToggleSystem $repoSystem
Test-Case 'repo system accepted' $true $true

$source = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ensure-ui-feature-toggles.ps1') -Raw
Test-Case 'script has no api key literal' ($source -match 'API-[A-Za-z0-9]{8,}') $false
Test-Case 'script does not say fleet' ($source -match '(?i)fleet') $false
Test-Case 'script calls featuretoggles' ($source -match '/featuretoggles') $true
Test-Case 'script does not call feature-flags' ($source -match '/feature-flags') $false

$projectBase = 'https://example.test/api/Spaces-355/projects/Projects-981'
Test-Case 'list uri' (Get-UiFeatureToggleListUri $projectBase 0 100) "$projectBase/featuretoggles?skip=0&take=100"
Test-Case 'create uri' (Get-UiFeatureToggleCollectionUri $projectBase) "$projectBase/featuretoggles"
Test-Case 'item uri' (Get-UiFeatureToggleItemUri $projectBase 'FeatureToggles-1') "$projectBase/featuretoggles/FeatureToggles-1"

$savedKey = $env:OCTOPUS_API_KEY
$env:OCTOPUS_API_KEY = 'test-only'
$script:octopusCalls = [System.Collections.Generic.List[object]]::new()
function Invoke-RestMethod {
    param(
        [Parameter(Mandatory)] [string] $Uri,
        $Headers,
        [string] $Method,
        $Body,
        [string] $ContentType
    )
    $script:octopusCalls.Add([pscustomobject]@{
            Uri      = [string]$Uri
            Method   = [string]$Method
            BodySent = [bool]$PSBoundParameters.ContainsKey('Body')
        })
    if ($Uri -like '*/environments/all') {
        $items = @(
            [pscustomobject]@{ Name = 'tdd'; Id = 'Environments-1' }
            [pscustomobject]@{ Name = 'uat'; Id = 'Environments-2' }
            [pscustomobject]@{ Name = 'prod'; Id = 'Environments-3' }
        )
        Write-Output $items -NoEnumerate
        return
    }
    return [pscustomobject]@{
        Items        = @([pscustomobject]@{ Id = 'FeatureToggles-1'; Name = 'BuildingManagement'; Slug = 'BuildingManagement' })
        TotalResults = 1
    }
}
try {
    $envs = @(Invoke-Octopus -Method Get -Uri 'https://example.test/api/Spaces-355/environments/all')
    Test-Case 'environments stay three' @($envs).Count 3
    Test-Case 'environment names stay apart' ((@($envs) | ForEach-Object { $_.Name }) -join ',') 'tdd,uat,prod'
    Test-Case 'get omits body' $script:octopusCalls[0].BodySent $false
    $script:octopusCalls.Clear()
    $listed = @(Get-UiFeatureToggleList -ProjectBase $projectBase)
    Test-Case 'list calls featuretoggles' $script:octopusCalls[0].Uri "$projectBase/featuretoggles?skip=0&take=100"
    Test-Case 'list reads the toggle' $listed[0].Name 'BuildingManagement'
    $script:octopusCalls.Clear()
    $null = Invoke-Octopus -Method Post -Uri (Get-UiFeatureToggleCollectionUri $projectBase) -Body '{"Name":"BuildingManagement"}'
    Test-Case 'post sends body' $script:octopusCalls[0].BodySent $true
    Test-Case 'post uri' $script:octopusCalls[0].Uri "$projectBase/featuretoggles"
} finally {
    if ($null -eq $savedKey) { Remove-Item Env:OCTOPUS_API_KEY -ErrorAction SilentlyContinue }
    else { $env:OCTOPUS_API_KEY = $savedKey }
    Remove-Item function:Invoke-RestMethod -ErrorAction SilentlyContinue
}

foreach ($case in @(
        @{ In = $true; Out = $true; Label = 'bool true' }
        @{ In = $false; Out = $false; Label = 'bool false' }
        @{ In = 'true'; Out = $true; Label = 'string true' }
        @{ In = 'false'; Out = $false; Label = 'string false' }
        @{ In = 'TRUE'; Out = $true; Label = 'string TRUE' }
        @{ In = 'False'; Out = $false; Label = 'string False' }
        @{ In = 'on'; Out = $true; Label = 'string on' }
        @{ In = 'off'; Out = $false; Label = 'string off' }
        @{ In = 'ON'; Out = $true; Label = 'string ON' }
        @{ In = 'OFF'; Out = $false; Label = 'string OFF' }
        @{ In = '1'; Out = $true; Label = 'string 1' }
        @{ In = '0'; Out = $false; Label = 'string 0' }
        @{ In = '$true'; Out = $true; Label = 'text dollar true' }
        @{ In = '$false'; Out = $false; Label = 'text dollar false' }
        @{ In = '$True'; Out = $true; Label = 'text dollar True' }
        @{ In = '$False'; Out = $false; Label = 'text dollar False' }
        @{ In = 1; Out = $true; Label = 'int 1' }
        @{ In = 0; Out = $false; Label = 'int 0' }
        @{ In = '  false  '; Out = $false; Label = 'padded false' }
    )) {
    Test-Case "parse $($case.Label)" (ConvertTo-UiFeatureToggleEnabled $case.In) $case.Out
}
Test-Case 'switch enable' (Resolve-UiFeatureToggleEnabled -Enable) $true
Test-Case 'switch disable' (Resolve-UiFeatureToggleEnabled -Disable) $false

foreach ($bad in @('', '   ', 'yes', 'no', '2', 'maybe', '$fals', 'falsey')) {
    $rejected = $false
    try { ConvertTo-UiFeatureToggleEnabled $bad | Out-Null } catch { $rejected = $true }
    Test-Case "reject [$bad]" $rejected $true
}
$secret = -join @('credential-sentinel-', [guid]::NewGuid().ToString('N'))
$secretMessage = ''
$secretRejected = $false
try { ConvertTo-UiFeatureToggleEnabled $secret | Out-Null } catch { $secretRejected = $true; $secretMessage = [string]$_.Exception.Message }
Test-Case 'parser rejects an arbitrary string' $secretRejected $true
if ($secretMessage.Contains($secret)) { Write-Host 'FAIL parser error contained the value'; $failures++ }
else { Write-Host 'PASS parser error omits the value' }

$runbook = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..' 'docs' 'ops' 'ui-feature-toggles.md') -Raw
Test-Case 'runbook turns tdd off' ($runbook.Contains('-Name BuildingManagement -Environment tdd -Enabled:false')) $true
Test-Case 'runbook turns tdd on' ($runbook.Contains('-Name BuildingManagement -Environment tdd -Enabled:true')) $true
Test-Case 'runbook reads back with show' ($runbook -match '(?s)-Enabled:false\r?\n.*-Action Show\r?\n.*-Enabled:true\r?\n.*-Action Show') $true
$fencesHaveDollarBool = $false
foreach ($fence in [regex]::Matches($runbook, '(?s)```[a-z]*\r?\n(.*?)```')) {
    if ($fence.Groups[1].Value -match '\$true|\$false') { $fencesHaveDollarBool = $true }
}
Test-Case 'runbook commands omit dollar bools' $fencesHaveDollarBool $false

$script:toggleState = @{
    'FeatureToggles-1' = @{
        Name             = 'BuildingManagement'
        Slug             = 'BuildingManagement'
        Description      = 'buildings'
        DefaultIsEnabled = $false
        Environments     = [ordered]@{
            'Environments-1' = $true
            'Environments-2' = $false
            'Environments-3' = $false
        }
    }
    'FeatureToggles-2' = @{
        Name             = 'VendorManagement'
        Slug             = 'VendorManagement'
        Description      = 'vendors'
        DefaultIsEnabled = $false
        Environments     = [ordered]@{
            'Environments-1' = $true
            'Environments-2' = $false
            'Environments-3' = $false
        }
    }
}
$script:octopusCalls = [System.Collections.Generic.List[object]]::new()

function New-FakeToggle([string] $Id) {
    $entry = $script:toggleState[$Id]
    $environments = foreach ($environmentId in @($entry.Environments.Keys)) {
        [pscustomobject]@{
            DeploymentEnvironmentId = [string]$environmentId
            IsEnabled               = [bool]$entry.Environments[$environmentId]
            Phases                  = @()
        }
    }
    return [pscustomobject]@{
        Id               = $Id
        Name             = [string]$entry.Name
        Slug             = [string]$entry.Slug
        Description      = [string]$entry.Description
        DefaultIsEnabled = [bool]$entry.DefaultIsEnabled
        Environments     = @($environments)
    }
}

function Invoke-RestMethod {
    throw 'live Invoke-RestMethod was called'
}

function Invoke-Octopus {
    param(
        [string] $Method,
        [string] $Uri,
        $Body
    )
    $bodyText = if ($PSBoundParameters.ContainsKey('Body') -and $null -ne $Body) { [string]$Body } else { '' }
    if ($bodyText.Contains($script:toggleCredential) -or $Uri.Contains($script:toggleCredential)) {
        throw 'octopus call carried the credential'
    }
    $script:octopusCalls.Add([pscustomobject]@{
            Method = [string]$Method
            Uri    = [string]$Uri
            Body   = $bodyText
        })
    if ($Uri -match '/projects/cmdemo1-ui$' -and $Method -eq 'Get') {
        return [pscustomobject]@{ Id = 'Projects-981'; Slug = 'cmdemo1-ui' }
    }
    if ($Uri -match '/environments/all$' -and $Method -eq 'Get') {
        # return enumerates, which is what Invoke-Octopus does with the environment list.
        return @(
            [pscustomobject]@{ Name = 'tdd'; Id = 'Environments-1' }
            [pscustomobject]@{ Name = 'uat'; Id = 'Environments-2' }
            [pscustomobject]@{ Name = 'prod'; Id = 'Environments-3' }
        )
    }
    if ($Uri -match '/featuretoggles\?' -and $Method -eq 'Get') {
        $items = foreach ($id in @($script:toggleState.Keys)) {
            $entry = $script:toggleState[$id]
            [pscustomobject]@{ Id = $id; Name = [string]$entry.Name; Slug = [string]$entry.Slug }
        }
        return [pscustomobject]@{ Items = @($items); TotalResults = @($items).Count }
    }
    if ($Uri -match '/featuretoggles/(FeatureToggles-\d+)$' -and $Method -eq 'Get') {
        return New-FakeToggle $Matches[1]
    }
    if ($Uri -match '/featuretoggles/(FeatureToggles-\d+)$' -and $Method -eq 'Put') {
        $id = $Matches[1]
        $parsed = $bodyText | ConvertFrom-Json
        foreach ($configured in @(ConvertTo-ObjectList $parsed.Environments)) {
            $environmentId = [string]$configured.DeploymentEnvironmentId
            $script:toggleState[$id].Environments[$environmentId] = [bool]$configured.IsEnabled
        }
        return New-FakeToggle $id
    }
    throw "unexpected octopus call $Method $Uri"
}

$savedKey = $env:OCTOPUS_API_KEY
$savedToken = $env:OCTOPUS_ACCESS_TOKEN
$script:toggleCredential = -join @('credential-sentinel-', [guid]::NewGuid().ToString('N'))
$env:OCTOPUS_API_KEY = $script:toggleCredential
Remove-Item Env:OCTOPUS_ACCESS_TOKEN -ErrorAction SilentlyContinue
$script:hostLines = [System.Collections.Generic.List[string]]::new()
function Write-Host {
    param([Parameter(Position = 0)] [object] $Object)
    $script:hostLines.Add([string]$Object)
}
$showOff = @()
$showOn = @()
$ensureMessage = ''
$bothMessage = ''
$mixedMessage = ''
$setOffLine = ''
$setOnLine = ''
$callsAfterReject = 0
try {
    try { Invoke-UiFeatureToggleCommand -Action Ensure -Enable } catch { $ensureMessage = [string]$_.Exception.Message }
    try { Invoke-UiFeatureToggleCommand -Action Set -Name BuildingManagement -Environment tdd -Enable -Disable } catch { $bothMessage = [string]$_.Exception.Message }
    try { Invoke-UiFeatureToggleCommand -Action Set -Name BuildingManagement -Environment tdd -Enabled 'false' -Disable } catch { $mixedMessage = [string]$_.Exception.Message }
    $callsAfterReject = $script:octopusCalls.Count

    $script:hostLines.Clear()
    Invoke-UiFeatureToggleCommand -Action Set -Name BuildingManagement -Environment tdd -Enabled '$false'
    $setOffLine = @($script:hostLines) -join "`n"

    $script:hostLines.Clear()
    Invoke-UiFeatureToggleCommand -Action Show
    $showOff = @($script:hostLines)

    $script:hostLines.Clear()
    Invoke-UiFeatureToggleCommand -Action Set -Name BuildingManagement -Environment tdd -Enabled:true
    $setOnLine = @($script:hostLines) -join "`n"

    $script:hostLines.Clear()
    Invoke-UiFeatureToggleCommand -Action Show
    $showOn = @($script:hostLines)

    Invoke-UiFeatureToggleCommand -Action Set -Name BuildingManagement -Environment tdd -Disable
    Invoke-UiFeatureToggleCommand -Action Set -Name BuildingManagement -Environment tdd -Enable
} finally {
    Remove-Item function:Write-Host -ErrorAction SilentlyContinue
    Remove-Item function:Invoke-Octopus -ErrorAction SilentlyContinue
    Remove-Item function:Invoke-RestMethod -ErrorAction SilentlyContinue
    if ($null -eq $savedKey) { Remove-Item Env:OCTOPUS_API_KEY -ErrorAction SilentlyContinue }
    else { $env:OCTOPUS_API_KEY = $savedKey }
    if ($null -eq $savedToken) { Remove-Item Env:OCTOPUS_ACCESS_TOKEN -ErrorAction SilentlyContinue }
    else { $env:OCTOPUS_ACCESS_TOKEN = $savedToken }
}

Test-Case 'ensure rejects enable' ($ensureMessage -match 'Ensure takes no') $true
Test-Case 'ensure reject made no call' $callsAfterReject 0
Test-Case 'enable and disable conflict' ($bothMessage -match 'not both') $true
Test-Case 'conflict made no call' $callsAfterReject 0
Test-Case 'enabled and disable conflict' ($mixedMessage -match 'not both') $true
Test-Case 'bash false string updates tdd' ($setOffLine -match 'BuildingManagement: update default=off tdd=off uat=off prod=off') $true
Test-Case 'colon true updates tdd' ($setOnLine -match 'BuildingManagement: update default=off tdd=on uat=off prod=off') $true

function Get-ShownEnvironment([string[]] $Lines, [string] $Toggle, [string] $Environment) {
    $inside = $false
    foreach ($line in $Lines) {
        if ($line -like "$Toggle`: *") { $inside = $true; continue }
        if ($inside -and $line -match '^\S') { break }
        if ($inside -and $line -match "^\s+$([regex]::Escape($Environment))\s+(on|off)$") { return $Matches[1] }
    }
    return ''
}
Test-Case 'show after off' (Get-ShownEnvironment $showOff 'BuildingManagement' 'tdd') 'off'
Test-Case 'show after off leaves uat' (Get-ShownEnvironment $showOff 'BuildingManagement' 'uat') 'off'
Test-Case 'show after off leaves prod' (Get-ShownEnvironment $showOff 'BuildingManagement' 'prod') 'off'
Test-Case 'show after on' (Get-ShownEnvironment $showOn 'BuildingManagement' 'tdd') 'on'
Test-Case 'show after on leaves uat' (Get-ShownEnvironment $showOn 'BuildingManagement' 'uat') 'off'
Test-Case 'show after on leaves prod' (Get-ShownEnvironment $showOn 'BuildingManagement' 'prod') 'off'
Test-Case 'vendor tdd stays on' (Get-ShownEnvironment $showOn 'VendorManagement' 'tdd') 'on'

$puts = @($script:octopusCalls | Where-Object { $_.Method -eq 'Put' })
Test-Case 'four writes for off on disable enable' $puts.Count 4
$putTargetsOk = $true
$uatProdStayOff = $true
foreach ($put in $puts) {
    if ($put.Uri -notmatch '/featuretoggles/FeatureToggles-1$') { $putTargetsOk = $false }
    $parsed = $put.Body | ConvertFrom-Json
    $byId = @{}
    foreach ($configured in @($parsed.Environments)) { $byId[[string]$configured.DeploymentEnvironmentId] = [bool]$configured.IsEnabled }
    if ($byId['Environments-2'] -or $byId['Environments-3']) { $uatProdStayOff = $false }
}
Test-Case 'writes touch only building management' $putTargetsOk $true
Test-Case 'writes leave uat and prod off' $uatProdStayOff $true
$posted = @($script:octopusCalls | Where-Object { $_.Method -eq 'Post' })
Test-Case 'mock did not create' $posted.Count 0
$carriedCredential = $false
foreach ($call in $script:octopusCalls) {
    if ($call.Uri.Contains($script:toggleCredential) -or $call.Body.Contains($script:toggleCredential)) { $carriedCredential = $true }
}
$shown = ($showOff + $showOn) -join "`n"
if ($carriedCredential -or $shown.Contains($script:toggleCredential) -or $setOffLine.Contains($script:toggleCredential) -or $setOnLine.Contains($script:toggleCredential)) {
    Write-Host 'FAIL output contained the credential'
    $failures++
} else {
    Write-Host 'PASS output omits the credential'
}

function Invoke-ToggleScriptFromBash {
    param([string[]] $Argument)
    $scriptPath = (Resolve-Path (Join-Path $PSScriptRoot 'ensure-ui-feature-toggles.ps1')).Path
    $quoted = ($Argument | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '
    $command = "env -u OCTOPUS_API_KEY -u OCTOPUS_ACCESS_TOKEN pwsh -NoProfile -File '$scriptPath' $quoted"
    $previous = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $output = & bash -lc $command 2>&1 | Out-String
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $previous
    }
}

$whatIf = Invoke-ToggleScriptFromBash -Argument @('-WhatIf')
Test-Case 'whatif exits clean' $whatIf.ExitCode 0
Test-Case 'whatif prints both creates' (($whatIf.Output -match 'BuildingManagement: create') -and ($whatIf.Output -match 'VendorManagement: create')) $true

$bashForms = @(
    @{ Label = 'colon false'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled:false') }
    @{ Label = 'colon true'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled:true') }
    @{ Label = 'word false'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', 'false') }
    @{ Label = 'word true'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', 'true') }
    @{ Label = 'word off'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', 'off') }
    @{ Label = 'word on'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', 'on') }
    @{ Label = 'word 0'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', '0') }
    @{ Label = 'word 1'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', '1') }
    @{ Label = 'quoted dollar false'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', '$false') }
    @{ Label = 'quoted dollar true'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', '$true') }
    @{ Label = 'disable switch'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Disable') }
    @{ Label = 'enable switch'; Args = @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enable') }
)
foreach ($form in $bashForms) {
    $result = Invoke-ToggleScriptFromBash -Argument $form.Args
    $parsed = ($result.ExitCode -eq 1) -and ($result.Output -match 'no Octopus credential') -and ($result.Output -notmatch 'argument transformation') -and ($result.Output -notmatch 'Missing an argument')
    Test-Case "bash accepts $($form.Label)" $parsed $true
}
$badBash = Invoke-ToggleScriptFromBash -Argument @('-Action', 'Set', '-Name', 'BuildingManagement', '-Environment', 'tdd', '-Enabled', 'maybe')
Test-Case 'bash rejects maybe' (($badBash.Output -match 'Enabled must be true') -and ($badBash.Output -notmatch 'no Octopus credential')) $true

$previousNative = $PSNativeCommandUseErrorActionPreference
$PSNativeCommandUseErrorActionPreference = $false
try {
    $pwshFalse = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'ensure-ui-feature-toggles.ps1') -Action Set -Name BuildingManagement -Environment tdd -Enabled $false 2>&1 | Out-String
    $pwshFalseCode = $LASTEXITCODE
    $pwshTrue = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'ensure-ui-feature-toggles.ps1') -Action Set -Name BuildingManagement -Environment tdd -Enabled $true 2>&1 | Out-String
    $pwshTrueCode = $LASTEXITCODE
} finally {
    $PSNativeCommandUseErrorActionPreference = $previousNative
}
Test-Case 'pwsh file false still binds' (($pwshFalseCode -eq 1) -and ($pwshFalse -match 'no Octopus credential') -and ($pwshFalse -notmatch 'argument transformation')) $true
Test-Case 'pwsh file true still binds' (($pwshTrueCode -eq 1) -and ($pwshTrue -match 'no Octopus credential')) $true

if ($failures -gt 0) { Write-Host "$failures FAILED"; exit 1 }
Write-Host 'OK'

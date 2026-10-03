#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Applies infra/ to one environment as the deployment stack stack-<slug>-<env>.

.DESCRIPTION
    Step "Apply environment" of the Octopus project <slug>-system; octopus/projects.tf inlines this file. The Azure
    CLI is signed in as the tier's deploy identity (Azure.Account, OIDC).

    - Templates come from the release's package <slug>-system: the commit that was already applied to the earlier
      environments, so a promotion applies exactly what was tested.
    - Versions come from environments/<env>/versions.json on main: the current desired state of the deployables,
      which the deployable projects' pin step writes.
    - The SQL administrator password is read from the environment's vault; the first apply generates it. It reaches
      the deployment through a private parameters file (mode 0600) that is removed afterwards, never a command line.
    - Deny settings (denyWriteAndDelete) block changes by anyone but the deploy identity: Git is the way in.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$root = [string] $OctopusParameters['Octopus.Action.Package[system].ExtractedPath']
$repository = [string] $OctopusParameters['System.Repository']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$deployPrincipalId = [string] $OctopusParameters['Azure.DeployPrincipalId']
$stackName = "stack-$slug-$environmentName"

function Get-DesiredVersion {
    # environments/<env>/versions.json on main, through the API (raw.githubusercontent.com caches for minutes).
    $headers = @{
        Authorization          = "Bearer $([string] $OctopusParameters['GitHub.Token'])"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $uri = "https://api.github.com/repos/$repository/contents/environments/$environmentName/versions.json?ref=main"
    try {
        $file = Invoke-RestMethod -Uri $uri -Headers $headers
    }
    catch {
        if ($_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 404) {
            Write-Warning "environments/$environmentName/versions.json is not on main yet: every deployable runs its placeholder."
            return @{}
        }
        throw
    }
    $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($file.content -replace '\s', '')))
    return $text | ConvertFrom-Json -AsHashtable
}

function Get-StackOutput {
    $PSNativeCommandUseErrorActionPreference = $false
    $json = az stack group show --name $stackName --resource-group $resourceGroup --output json 2>$null
    $found = $LASTEXITCODE -eq 0
    $PSNativeCommandUseErrorActionPreference = $true
    if (-not $found) {
        return $null
    }
    return ($json | ConvertFrom-Json -AsHashtable).outputs
}

function New-SqlPassword {
    # 32 characters with every class SQL Server's complexity rule asks for, from a cryptographic generator.
    $classes = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '-_.~')
    $all = -join $classes
    $characters = [Collections.Generic.List[char]]::new()
    foreach ($class in $classes) {
        $characters.Add($class[[Security.Cryptography.RandomNumberGenerator]::GetInt32($class.Length)])
    }
    while ($characters.Count -lt 32) {
        $characters.Add($all[[Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    return -join ($characters | Sort-Object { [Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

function Get-SqlPassword {
    param([hashtable] $Outputs)

    if (-not $Outputs -or -not $Outputs.ContainsKey('keyVaultName')) {
        Write-Highlight "Stack $stackName does not exist yet: generating the SQL administrator password."
        return New-SqlPassword
    }
    $vault = [string] $Outputs.keyVaultName.value
    # The vault role of the deploy identity can take a few minutes to apply after the first stack.
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        $PSNativeCommandUseErrorActionPreference = $false
        $value = az keyvault secret show --vault-name $vault --name sql-admin-password --query value --output tsv 2>$null
        $read = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
        if ($read -and $value) {
            return ([string] $value).Trim()
        }
        Write-Host "Waiting for read access to vault $vault (attempt $attempt of 6)"
        Start-Sleep -Seconds 30
    }
    Fail-Step "Cannot read sql-admin-password from vault $vault as the deploy identity. Check its Key Vault Secrets Officer assignment."
}

$template = Join-Path $root 'infra' 'main.bicep'
if (-not (Test-Path -LiteralPath $template)) {
    Fail-Step "Package <slug>-system has no infra/main.bicep under $root."
}

$versions = Get-DesiredVersion
$outputs = Get-StackOutput
$password = Get-SqlPassword -Outputs $outputs
Write-Host "Environment $environmentName, resource group $resourceGroup, stack $stackName"
Write-Host "Versions on main: $(if ($versions.Count) { ($versions.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', ' } else { 'none (placeholders)' })"

$parameters = @{
    '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
    contentVersion = '1.0.0.0'
    parameters     = @{
        environmentName   = @{ value = $environmentName }
        versions          = @{ value = $versions }
        sqlAdminPassword  = @{ value = $password }
        deployPrincipalId = @{ value = $deployPrincipalId }
    }
}
$parametersFile = Join-Path ([IO.Path]::GetTempPath()) "stack-$([Guid]::NewGuid().ToString('N')).json"
New-Item -ItemType File -Path $parametersFile | Out-Null
if (-not $IsWindows) {
    [IO.File]::SetUnixFileMode($parametersFile, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
}
$parameters | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $parametersFile -Encoding utf8NoBOM

try {
    $result = $null
    # New role assignments and identities take a few minutes to propagate: the first apply of an environment can fail
    # once on them, so it is retried.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $PSNativeCommandUseErrorActionPreference = $false
        $result = az stack group create `
            --name $stackName `
            --resource-group $resourceGroup `
            --template-file $template `
            --parameters "@$parametersFile" `
            --action-on-unmanage deleteResources `
            --deny-settings-mode denyWriteAndDelete `
            --deny-settings-excluded-principals $deployPrincipalId `
            --yes `
            --output json
        $applied = $LASTEXITCODE -eq 0
        $PSNativeCommandUseErrorActionPreference = $true
        if ($applied) {
            break
        }
        if ($attempt -eq 3) {
            Fail-Step "az stack group create failed three times for $stackName; the error is above."
        }
        Write-Warning "az stack group create failed (attempt $attempt of 3); retrying in 90 seconds."
        Start-Sleep -Seconds 90
    }
}
finally {
    Remove-Item -LiteralPath $parametersFile -Force -ErrorAction SilentlyContinue
}

$stack = $result | ConvertFrom-Json -AsHashtable
foreach ($deployable in $stack.outputs.deployables.value) {
    $label = if ($deployable.version) { $deployable.version } else { 'placeholder' }
    Write-Highlight "$($deployable.name) in ${environmentName}: $($deployable.url) ($label)"
    Set-OctopusVariable -name "Url.$($deployable.name)" -value $deployable.url
}
Write-Highlight "Capabilities of ${environmentName}: $($stack.outputs.capabilities.value -join ', ')"

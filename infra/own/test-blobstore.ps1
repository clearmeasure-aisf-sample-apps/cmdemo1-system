#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Checks the blob store of the deployable scorecard (infra/own/main.bicep) in one environment. Read-only.

.DESCRIPTION
    The system's own checks, beside the module they belong to (the kit's catalog entry blob-store, "Checks that go
    with it"). Run as an identity that may read the environment's resource group:

      1. the storage account allows no public blob access and no shared key;
      2. the container is private;
      3. the deployable's identity holds Storage Blob Data Contributor at the container's scope, and no role on the
         account or the container besides it;
      4. the container app gets the two settings, and neither they nor any other setting of it holds a storage key.

    An environment in which the deployable does not exist has no store: the script says so and passes. Exit 1 when a
    check fails.

.EXAMPLE
    pwsh -NoProfile -File infra/own/test-blobstore.ps1 -Environment tdd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$system = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$deployable = 'scorecard'
$environmentEntry = @($system.environments | Where-Object { $_.name -eq $Environment })
if ($environmentEntry.Count -ne 1) { throw "system.json has no environment '$Environment'." }
$group = [string] $system.azure.resourceGroups[[string] $environmentEntry[0].tier]
$entry = @($system.deployables | Where-Object { $_.name -eq $deployable })
$exists = $entry.Count -eq 1 -and (-not $entry[0].ContainsKey('environments') -or $Environment -in @($entry[0].environments))
if (-not $exists) {
    Write-Host "SKIP blob store: $deployable does not exist in $Environment."
    exit 0
}

$failed = 0
function Test-That {
    param([string] $What, [bool] $Holds, [string] $Otherwise = '')
    if ($Holds) { Write-Host "PASS $What" } else { Write-Host "FAIL $What$(if ($Otherwise) { ": $Otherwise" })"; $script:failed++ }
}

$accounts = @(az storage account list --resource-group $group --query "[?starts_with(name, 'st$slug$Environment')]" --output json | ConvertFrom-Json)
Test-That "one storage account st$slug$Environment* in $group" ($accounts.Count -eq 1) "$($accounts.Count) found"
if ($accounts.Count -ne 1) { exit 1 }
$account = $accounts[0]
Test-That "$($account.name) allows no public blob access" ($account.allowBlobPublicAccess -eq $false)
Test-That "$($account.name) allows no shared key" ($account.allowSharedKeyAccess -eq $false)

$container = az storage container-rm show --storage-account $account.name --resource-group $group --name $deployable --output json | ConvertFrom-Json
Test-That "container $deployable is private" ([string] $container.publicAccess -in '', 'None')

$identity = az identity show --resource-group $group --name "id-$slug-$Environment-$deployable" --output json | ConvertFrom-Json
$containerScope = "$($account.id)/blobServices/default/containers/$deployable"
$roles = @(az role assignment list --assignee $identity.principalId --scope $account.id --include-inherited false --output json | ConvertFrom-Json) +
    @(az role assignment list --assignee $identity.principalId --scope $containerScope --output json | ConvertFrom-Json | Where-Object { $_.scope -eq $containerScope })
$atContainer = @($roles | Where-Object { $_.scope -eq $containerScope })
$elsewhere = @($roles | Where-Object { $_.scope -ne $containerScope -and $_.scope -like "$($account.id)*" })
Test-That "the identity of $deployable holds Storage Blob Data Contributor at the container's scope" (@($atContainer | Where-Object { $_.roleDefinitionName -eq 'Storage Blob Data Contributor' }).Count -eq 1)
Test-That 'it holds no other role on the container' ($atContainer.Count -eq 1) "$(@($atContainer.roleDefinitionName) -join ', ')"
Test-That 'it holds no role on the account itself' ($elsewhere.Count -eq 0) "$(@($elsewhere.roleDefinitionName) -join ', ')"

$apps = @(az containerapp list --resource-group $group --query "[?contains(name, '-$Environment-$deployable')]" --output json | ConvertFrom-Json)
Test-That "one container app of $deployable in $Environment" ($apps.Count -eq 1) "$($apps.Count) found"
if ($apps.Count -eq 1) {
    $settings = @($apps[0].properties.template.containers[0].env)
    $uri = @($settings | Where-Object { $_.name -eq 'Scorecard__Storage__ContainerUri' })
    $client = @($settings | Where-Object { $_.name -eq 'Scorecard__Storage__ManagedIdentityClientId' })
    Test-That 'the app gets the container address' ($uri.Count -eq 1 -and [string] $uri[0].value -eq "https://$($account.name).blob.core.windows.net/$deployable")
    Test-That "the app gets the client id of its own identity" ($client.Count -eq 1 -and [string] $client[0].value -eq [string] $identity.clientId)
    # A storage key or a connection string in a setting would be the key the store is built to do without.
    $keyLike = @($settings | Where-Object { $_.PSObject.Properties['value'] -and [string] $_.value -match 'AccountKey=|SharedAccessSignature=|[?&]sig=' })
    Test-That 'no setting of the app holds a storage key or a signed address' ($keyLike.Count -eq 0) "$(@($keyLike.name) -join ', ')"
}

if ($failed -gt 0) { Write-Host "$failed check(s) of the blob store failed in $Environment."; exit 1 }
Write-Host "The blob store of $deployable in $Environment is as declared."

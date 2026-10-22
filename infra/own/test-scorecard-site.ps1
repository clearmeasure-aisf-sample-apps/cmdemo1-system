#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Checks the space scorecard's published site (infra/own/main.bicep, purpose space-scorecard) in one environment.
    Read-only.

.DESCRIPTION
    The system's own checks of the site the nightly runbook "Refresh space scorecard" publishes (space-scorecard/ of
    this repository). Run as an identity that may read the environment's resource group:

      1. one storage account tagged purpose space-scorecard; it takes no shared key;
      2. its containers are "scorecard" and one "scorecard-<prefix>" per other space of scorecard-site-spaces.json,
         no other; each allows anonymous reads of single blobs (publicAccess Blob, not Container: it cannot be
         listed);
      3. the site's identity id-<slug>-<env>-scorecard-site holds Storage Blob Data Contributor at the scope of each
         of those containers, no other role on the account, and signs in only for runs of project
         <slug>-scorecard-space of this environment and of <prefix>-scorecard-space of each other space's environment
         of the same name (one federated credential each).

    The site exists in prod only: in another environment the script checks that there is none, and passes. Exit 1
    when a check fails.

.EXAMPLE
    pwsh -NoProfile -File infra/own/test-scorecard-site.ps1 -Environment prod
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
$environmentEntry = @($system.environments | Where-Object { $_.name -eq $Environment })
if ($environmentEntry.Count -ne 1) { throw "system.json has no environment '$Environment'." }
$group = [string] $system.azure.resourceGroups[[string] $environmentEntry[0].tier]
$otherSpaces = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot 'scorecard-site-spaces.json') -Raw | ConvertFrom-Json -AsHashtable)

$failed = 0
function Test-That {
    param([string] $What, [bool] $Holds, [string] $Otherwise = '')
    if ($Holds) { Write-Host "PASS $What" } else { Write-Host "FAIL $What$(if ($Otherwise) { ": $Otherwise" })"; $script:failed++ }
}

$accounts = @(az storage account list --resource-group $group --query "[?tags.purpose == 'space-scorecard' && tags.environment == '$Environment']" --output json | ConvertFrom-Json)
if ($Environment -ne 'prod') {
    Test-That "no space scorecard site in $Environment" ($accounts.Count -eq 0) "$($accounts.Count) found"
    if ($failed -gt 0) { exit 1 }
    exit 0
}

Test-That "one storage account of the space scorecard site in $group" ($accounts.Count -eq 1) "$($accounts.Count) found"
if ($accounts.Count -ne 1) { exit 1 }
$account = $accounts[0]
Test-That "$($account.name) allows no shared key" ($account.allowSharedKeyAccess -eq $false)

$containers = @(az storage container-rm list --storage-account $account.name --resource-group $group --output json | ConvertFrom-Json)
$wantedContainers = @('scorecard') + @($otherSpaces | ForEach-Object { "scorecard-$($_.prefix)" })
$heldContainers = @($containers | ForEach-Object { [string] $_.name })
Test-That "its containers are $($wantedContainers -join ', ')" ((@($heldContainers | Sort-Object) -join ',') -ceq (@($wantedContainers | Sort-Object) -join ',')) "$($heldContainers -join ', ')"
foreach ($name in $wantedContainers) {
    $pages = @($containers | Where-Object { $_.name -eq $name })
    Test-That "container $name allows anonymous reads of single blobs, not listing" ($pages.Count -eq 1 -and [string] $pages[0].publicAccess -eq 'Blob')
}

$identityName = "id-$slug-$Environment-scorecard-site"
$identity = az identity show --resource-group $group --name $identityName --output json | ConvertFrom-Json
$scopes = @($wantedContainers | ForEach-Object { "$($account.id)/blobServices/default/containers/$_" })
$roles = @(az role assignment list --assignee $identity.principalId --scope $account.id --output json | ConvertFrom-Json)
# Only the containers that exist: a missing one has failed above, and az refuses a scope that is not there.
foreach ($scope in @($scopes | Where-Object { $heldContainers -ccontains $_.Split('/')[-1] })) { $roles += @(az role assignment list --assignee $identity.principalId --scope $scope --output json | ConvertFrom-Json | Where-Object { $_.scope -eq $scope }) }
foreach ($scope in $scopes) {
    $atContainer = @($roles | Where-Object { $_.scope -eq $scope })
    $name = $scope.Split('/')[-1]
    Test-That "$identityName holds Storage Blob Data Contributor at the scope of $name" (@($atContainer | Where-Object { $_.roleDefinitionName -eq 'Storage Blob Data Contributor' }).Count -eq 1)
    Test-That "it holds no other role on $name" ($atContainer.Count -eq 1) "$(($atContainer | ForEach-Object { $_.roleDefinitionName }) -join ', ')"
}
$elsewhere = @($roles | Where-Object { $_.scope -notin $scopes -and $_.scope -like "$($account.id)*" })
Test-That 'it holds no role on the account itself' ($elsewhere.Count -eq 0) "$(($elsewhere | ForEach-Object { $_.roleDefinitionName }) -join ', ')"

$credentials = @(az identity federated-credential list --identity-name $identityName --resource-group $group --output json | ConvertFrom-Json)
$subjects = @("space:$($system.octopus.spaceSlug):project:$slug-scorecard-space:environment:$Environment") + @($otherSpaces | ForEach-Object { "space:$($_.spaceSlug):project:$($_.prefix)-scorecard-space:environment:$Environment" })
$held = @($credentials | ForEach-Object { [string] $_.subject })
$issuers = @($credentials | Where-Object { $_.issuer -cne $system.octopus.url })
Test-That "$identityName signs in only for runs of $(($subjects | ForEach-Object { ($_ -split ':')[3] }) -join ', ') in $Environment" ((@($held | Sort-Object) -join ',') -ceq (@($subjects | Sort-Object) -join ',') -and $issuers.Count -eq 0) "$(($credentials | ForEach-Object { "$($_.issuer) $($_.subject)" }) -join '; ')"

if ($failed -gt 0) { Write-Host "$failed check(s) of the space scorecard site failed in $Environment."; exit 1 }
Write-Host "The space scorecard site in $Environment is as declared."

#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Deploys the release's zip to the deployable's App Service web app.

.DESCRIPTION
    Step "Update deployable" of an Octopus project <slug>-<deployable> whose deployable is hosted on App Service
    (system.json hosting "appservice"); octopus/projects.tf inlines this file. The package reference "app" is the zip
    the app's release workflow pushed to the Octopus built-in feed (<slug>-<deployable>.<version>.zip, the published
    app). The web app is the one the stack created (stack output deployables[].webApp); the deploy identity is excluded
    from the stack's deny settings, so it may deploy to it. "Verify deployable" then waits for the health path.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'

# Every step starts in a fresh worker container. The Azure CLI writes progress spinners and, when it installs Bicep,
# a WARNING line to stderr, which Octopus logs as errors ("SuccessWithWarning"): turn both off.
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'
$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'

$environmentName = [string] $OctopusParameters['Octopus.Environment.Name']
$slug = [string] $OctopusParameters['System.Slug']
$resourceGroup = [string] $OctopusParameters['Azure.ResourceGroup']
$name = [string] $OctopusParameters['Deployable.Name']
$version = [string] $OctopusParameters['Octopus.Release.Number']
$package = [string] $OctopusParameters['Octopus.Action.Package[app].PackageFilePath']

if (-not $package -or -not (Test-Path -LiteralPath $package)) {
    Fail-Step "The release has no app package for $name ($package)."
}
$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$entry = @($outputs.deployables.value | Where-Object { $_.name -eq $name -and $_['hosting'] -eq 'appservice' }) | Select-Object -First 1
if (-not $entry) {
    Fail-Step "Stack stack-$slug-$environmentName has no App Service deployable named ${name}: deploy the latest $slug-system release to $environmentName first."
}
$webApp = [string] $entry.webApp

Write-Host "Deploying $name $version ($([Math]::Round((Get-Item -LiteralPath $package).Length / 1MB)) MB) to $webApp"
# az webapp deploy reports its progress as WARNING lines, which Octopus would log as warnings: errors only. A failed
# deployment still fails the command.
az webapp deploy --resource-group $resourceGroup --name $webApp --src-path $package --type zip --async false `
    --restart true --only-show-errors --output none
Write-Highlight "$name $version deployed to $webApp in $environmentName"

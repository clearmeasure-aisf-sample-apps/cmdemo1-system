#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Opens the environment's database to this deployment's worker for the acceptance tests.

.DESCRIPTION
    Step "Open test database" of the Octopus project <slug>-<deployable>, in the environments whose system.json entry
    has "acceptanceTests": true; octopus/projects.tf inlines this file. It adds a SQL firewall rule for the worker's
    address and hands the next steps what they need as output variables: the app's URL, and the connection string
    from the environment's Key Vault (sensitive, masked in the log). Step "Close test database" removes the rule.
    The test steps run in another container on the same worker, so they reach SQL from the same address.
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
$deployable = [string] $OctopusParameters['Deployable.Name']
$ruleName = "octopus-tests-$(([string] $OctopusParameters['Octopus.Deployment.Id']) -replace '[^A-Za-z0-9-]', '-')"

$outputs = (az stack group show --name "stack-$slug-$environmentName" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$server = [string] $outputs.sqlServerName.value
$vault = [string] $outputs.keyVaultName.value
$fqdn = ([string] (@($outputs.deployables.value | Where-Object { $_.name -eq $deployable }) | Select-Object -First 1).url) -replace '^https://', ''

# The address is read from three services, five rounds, so one bad answer (a 502 failed a deployment once) does not stop a step.
$workerIp = $null
for ($attempt = 1; -not $workerIp -and $attempt -le 5; $attempt++) {
    foreach ($addressService in 'https://api.ipify.org', 'https://checkip.amazonaws.com', 'https://ifconfig.me/ip') {
        try {
            $answer = (Invoke-RestMethod -Uri $addressService -TimeoutSec 15).ToString().Trim()
            if ($answer -match '^\d{1,3}(\.\d{1,3}){3}$') { $workerIp = $answer; break }
        }
        catch {
            Write-Host "SKIP $addressService did not answer: $($_.Exception.Message)"
        }
    }
    if (-not $workerIp -and $attempt -lt 5) { Start-Sleep -Seconds (5 * $attempt) }
}
if (-not $workerIp) { throw 'The address of this worker could not be read from any of three services in five rounds.' }
Write-Host "Opening $server to the worker ($workerIp) as rule $ruleName"
az sql server firewall-rule create --resource-group $resourceGroup --server $server --name $ruleName `
    --start-ip-address $workerIp --end-ip-address $workerIp --output none

$connectionString = ([string] (az keyvault secret show --vault-name $vault --name sql-connection-string --query value --output tsv)).Trim()
Set-OctopusVariable -name 'SqlConnectionString' -value $connectionString -sensitive
Set-OctopusVariable -name 'ApplicationBaseUrl' -value "https://$fqdn"
Set-OctopusVariable -name 'SqlServer' -value $server
Set-OctopusVariable -name 'FirewallRule' -value $ruleName
Set-OctopusVariable -name 'Opened' -value 'True'
Write-Highlight "Acceptance tests of $environmentName target https://$fqdn"

# Said as an exit code: Octopus ends a step with the exit code of the last program its script ran, which may be one
# whose refusal was expected and handled (a dormant system's resources that are gone: cmdemo2, 2026-10-15).
exit 0

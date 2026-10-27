#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Gives the factory worker gateway's identity its contained user in the gateway's own database (infra/own/main.bicep).

.DESCRIPTION
    Run by the operator, signed in to Azure as cm-ai-ops (the account aiops), the server's Entra administrator that
    infra/own/main.bicep sets, after a deployment that created the database sqldb-<slug>-<env>-fworker. It finds the
    server and the database from the environment's stack, signs in to the database with an Entra token of the caller
    (no password), and makes the user id-<slug>-<env>-fworker of the gateway's identity with db_datareader,
    db_datawriter and db_ddladmin (the gateway runs its own migrations), on that database only. The user is made from
    the identity's client ID (CREATE USER ... WITH SID, TYPE = E), so the server needs no right to read the directory.
    Running it again changes nothing.

    The caller's address gets a firewall rule for the duration of the run. A paused serverless database resumes only on
    a login attempt, so the script logs in again until it answers, for up to five minutes.

.EXAMPLE
    pwsh -NoProfile -File infra/own/grant-fworker-database.ps1 -Environment tdd
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Environment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandArgumentPassing = 'Standard'
$PSNativeCommandUseErrorActionPreference = $true
$ProgressPreference = 'SilentlyContinue'
$env:AZURE_CORE_DISABLE_PROGRESS_BAR = 'true'

$repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$system = Get-Content -LiteralPath (Join-Path $repository 'system.json') -Raw | ConvertFrom-Json -AsHashtable
$slug = [string] $system.system.slug
$tier = [string] ($system.environments | Where-Object { $_.name -eq $Environment }).tier
if (-not $tier) { throw "No environment $Environment in system.json." }
$resourceGroup = [string] $system.azure.resourceGroups[$tier]

$outputs = (az stack group show --name "stack-$slug-$Environment" --resource-group $resourceGroup --output json | ConvertFrom-Json -AsHashtable).outputs
$server = [string] $outputs.sqlServerName.value
$serverFqdn = [string] $outputs.sqlServerFqdn.value
$database = "sqldb-$slug-$Environment-fworker"
$userName = "id-$slug-$Environment-fworker"
$clientId = [string] (az identity show --resource-group $resourceGroup --name $userName --query clientId --output tsv)
$null = az sql db show --resource-group $resourceGroup --server $server --name $database --query name --output tsv

$grant = @'
DECLARE @sql nvarchar(max);
DECLARE @sid varbinary(16) = CONVERT(varbinary(16), CAST(@clientId AS uniqueidentifier));
IF EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name AND sid <> @sid)
    THROW 50000, 'A user of that name exists with another SID: drop it first.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = @name)
BEGIN
    SET @sql = N'CREATE USER ' + QUOTENAME(@name) + N' WITH SID = ' + CONVERT(nvarchar(64), @sid, 1) + N', TYPE = E';
    EXEC sys.sp_executesql @sql;
END
IF IS_ROLEMEMBER(N'db_datareader', @name) = 0
BEGIN
    SET @sql = N'ALTER ROLE db_datareader ADD MEMBER ' + QUOTENAME(@name);
    EXEC sys.sp_executesql @sql;
END
IF IS_ROLEMEMBER(N'db_datawriter', @name) = 0
BEGIN
    SET @sql = N'ALTER ROLE db_datawriter ADD MEMBER ' + QUOTENAME(@name);
    EXEC sys.sp_executesql @sql;
END
IF IS_ROLEMEMBER(N'db_ddladmin', @name) = 0
BEGIN
    SET @sql = N'ALTER ROLE db_ddladmin ADD MEMBER ' + QUOTENAME(@name);
    EXEC sys.sp_executesql @sql;
END
SELECT p.name, p.type_desc, p.authentication_type_desc,
    IS_ROLEMEMBER(N'db_datareader', p.name) AS reader,
    IS_ROLEMEMBER(N'db_datawriter', p.name) AS writer,
    IS_ROLEMEMBER(N'db_ddladmin', p.name) AS ddladmin
FROM sys.database_principals AS p WHERE p.name = @name;
'@

$callerIp = ([string] (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 15)).Trim()
if ($callerIp -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { throw "Unexpected address from api.ipify.org: $callerIp" }
$ruleName = "operator-grant-fworker-$(Get-Date -Format 'yyyyMMddHHmmss')"
Write-Host "Opening $server to $callerIp as rule $ruleName"
az sql server firewall-rule create --resource-group $resourceGroup --server $server --name $ruleName `
    --start-ip-address $callerIp --end-ip-address $callerIp --output none
try {
    $token = [string] (az account get-access-token --resource 'https://database.windows.net/' --query accessToken --output tsv)
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = "tcp:$serverFqdn,1433"
    $builder['Initial Catalog'] = $database
    $builder['Encrypt'] = $true
    $builder['Connect Timeout'] = 30
    $deadline = (Get-Date).AddMinutes(5)
    for ($attempt = 1; ; $attempt++) {
        $connection = [System.Data.SqlClient.SqlConnection]::new($builder.ConnectionString)
        $connection.AccessToken = $token
        try {
            $connection.Open()
            break
        }
        catch {
            $connection.Dispose()
            $reason = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
            if ((Get-Date) -gt $deadline) { throw "Database $database did not accept a login within 5 minutes: $reason" }
            Write-Host "Waiting for database $database (attempt $attempt): $reason"
            Start-Sleep -Seconds 15
        }
    }
    try {
        $command = $connection.CreateCommand()
        $command.CommandText = $grant
        $null = $command.Parameters.AddWithValue('@name', $userName)
        $null = $command.Parameters.AddWithValue('@clientId', $clientId)
        $reader = $command.ExecuteReader()
        while ($reader.Read()) {
            Write-Host ("User {0} ({1}, {2}) in {3}: db_datareader {4}, db_datawriter {5}, db_ddladmin {6}" -f `
                    $reader['name'], $reader['type_desc'], $reader['authentication_type_desc'], $database, `
                    $reader['reader'], $reader['writer'], $reader['ddladmin'])
        }
        $reader.Dispose()
    }
    finally {
        $connection.Dispose()
    }
}
finally {
    $PSNativeCommandUseErrorActionPreference = $false
    az sql server firewall-rule delete --resource-group $resourceGroup --server $server --name $ruleName --output none
    $PSNativeCommandUseErrorActionPreference = $true
}
exit 0

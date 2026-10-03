// Desired state of ONE environment of the system. Octopus applies it as the deployment stack stack-<slug>-<env>
// (scripts/apply-environment.ps1); pull requests preview it with what-if (scripts/preview-environment.ps1).
// Everything about the system comes from ../system.json; this file only reads it. An environment's capabilities
// (system.json, environments[].capabilities) switch modules on: "baseline" is always on, "telemetry" adds Log
// Analytics and Application Insights. A new capability is a new module plus one condition here.
targetScope = 'resourceGroup'

@description('Name of the environment in system.json, for example tdd.')
param environmentName string

@description('Deployed version of each deployable, from environments/<env>/versions.json on main. Empty means none yet: a placeholder runs.')
param versions object = {}

@description('SQL administrator password; apply-environment.ps1 reads it from the vault, or generates it on the first apply.')
@secure()
param sqlAdminPassword string

@description('Principal ID of the deploy identity of this tier; it may read and write the vault secrets.')
param deployPrincipalId string

var system = loadJsonContent('../system.json')
var slug = system.system.slug
var location = system.system.location
var environment = first(filter(system.environments, e => e.name == environmentName))!
var capabilities = union(['baseline'], environment.capabilities)
var app = first(filter(system.azure.identities.apps, a => a.environment == environmentName))!
var suffix = take(uniqueString(subscription().id, resourceGroup().id, environmentName), 5)
var tags = {
  system: slug
  environment: environmentName
  tier: environment.tier
  purpose: 'demo'
}

var vaultName = take('kv${slug}${environmentName}${suffix}', 24)
var sqlServerName = 'sql-${slug}-${environmentName}-${suffix}'
var databaseName = 'sqldb-${slug}-${environmentName}'
var sqlAdminLogin = 'sqladmin'
var sqlServerFqdn = '${sqlServerName}${az.environment().suffixes.sqlServerHostname}'

module telemetry 'modules/telemetry.bicep' = if (contains(capabilities, 'telemetry')) {
  name: 'telemetry-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: location
    tags: tags
  }
}

module sql 'modules/sql.bicep' = {
  name: 'sql-${environmentName}'
  params: {
    serverName: sqlServerName
    databaseName: databaseName
    location: location
    tags: tags
    administratorLogin: sqlAdminLogin
    administratorPassword: sqlAdminPassword
  }
}

module vault 'modules/keyvault.bicep' = {
  name: 'vault-${environmentName}'
  params: {
    name: vaultName
    location: location
    tags: tags
    readerPrincipalIds: [app.principalId]
    officerPrincipalIds: [deployPrincipalId]
    sqlAdminPassword: sqlAdminPassword
    sqlConnectionString: 'Server=tcp:${sqlServerFqdn},1433;Database=${databaseName};User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
  }
}

module apps 'modules/containerapps.bicep' = {
  name: 'apps-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: location
    tags: tags
    deployables: system.deployables
    versions: versions
    registryServer: system.azure.registry.loginServer
    identityResourceId: app.resourceId
    connectionStringSecretUri: vault.outputs.connectionStringSecretUri
    applicationInsightsConnectionString: contains(capabilities, 'telemetry') ? telemetry!.outputs.connectionString : ''
  }
}

output keyVaultName string = vaultName
output sqlServerName string = sqlServerName
output sqlServerFqdn string = sqlServerFqdn
output databaseName string = databaseName
output sqlAdminLogin string = sqlAdminLogin
output deployables array = apps.outputs.deployables
output capabilities array = capabilities

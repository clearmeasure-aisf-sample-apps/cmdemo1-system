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

@description('Password of the database login of each App Service deployable, by name; apply-environment.ps1 reads them from the vault, or generates them for a new deployable.')
@secure()
param loginPasswords object = {}

var system = loadJsonContent('../system.json')
var slug = system.system.slug
var location = system.system.location
// Azure SQL may need its own region: subscription offers restrict where new SQL servers can be created
// (RegionDoesNotAllowProvisioning). system.sqlLocation overrides location for the SQL server and database only.
// Optional keys come from defaults merged with union(): reading a key absent from system.json (.?key) is warning
// BCP053, and the build treats warnings as errors.
var sqlLocation = union({ sqlLocation: location }, system.system).sqlLocation
// The Container Apps environment, its apps and telemetry may need another region per environment: a subscription
// offer may allow only a few Container Apps environments per region (ManagedEnvironmentCount).
// environments[].appLocation overrides location for those only.
var environment = union({ appLocation: location, appCpu: '0.5' }, first(filter(system.environments, e => e.name == environmentName))!)
var capabilities = union(['baseline'], environment.capabilities)
var appLocation = environment.appLocation
// A Container Apps environment that failed in one region keeps its name there; an appLocation gets a name of its own.
var managedEnvironmentName = appLocation == location ? 'cae-${slug}-${environmentName}' : 'cae-${slug}-${environmentName}-${take(uniqueString(appLocation), 4)}'
var app = first(filter(system.azure.identities.apps, a => a.environment == environmentName))!
var suffix = take(uniqueString(subscription().id, resourceGroup().id, environmentName), 5)
var tags = {
  system: slug
  environment: environmentName
  tier: environment.tier
  purpose: 'demo'
}

var vaultName = take('kv${slug}${environmentName}${suffix}', 24)
// SQL server names are global, and a create refused in one region keeps the name from another for a while; a SQL
// region of its own therefore gets a name of its own (unchanged when sqlLocation is location).
var sqlSuffix = sqlLocation == location ? suffix : take(uniqueString(subscription().id, resourceGroup().id, environmentName, sqlLocation), 5)
var sqlServerName = 'sql-${slug}-${environmentName}-${sqlSuffix}'
var databaseName = 'sqldb-${slug}-${environmentName}'
var sqlAdminLogin = 'sqladmin'
var sqlServerFqdn = '${sqlServerName}${az.environment().suffixes.sqlServerHostname}'

// A deployable runs as a container app (modules/containerapps.bicep) unless deployables[].hosting is "appservice": then
// a Linux web app on the Free plan (modules/appservice.bicep). An App Service deployable has no database of its own and
// runs no migrations: it reaches the system's database with a login of its own (scripts/grant-database-access.ps1),
// whose connection string only its identity may read.
var hostedDeployables = map(system.deployables, d => union({ hosting: 'containerapp' }, d))
var containerDeployables = filter(hostedDeployables, d => d.hosting == 'containerapp')
var appServiceDeployables = filter(hostedDeployables, d => d.hosting == 'appservice')

resource loginIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for d in appServiceDeployables: {
    name: 'id-${slug}-${environmentName}-${d.name}'
    location: appLocation
    tags: union(tags, { deployable: d.name })
  }
]

module telemetry 'modules/telemetry.bicep' = if (contains(capabilities, 'telemetry')) {
  name: 'telemetry-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: appLocation
    tags: tags
  }
}

module sql 'modules/sql.bicep' = {
  name: 'sql-${environmentName}'
  params: {
    serverName: sqlServerName
    databaseName: databaseName
    location: sqlLocation
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
    logins: [
      for (d, i) in appServiceDeployables: {
        name: d.name
        principalId: loginIdentities[i].properties.principalId
      }
    ]
    loginPasswords: loginPasswords
    loginConnectionStrings: toObject(
      appServiceDeployables,
      d => d.name,
      d =>
        'Server=tcp:${sqlServerFqdn},1433;Database=${databaseName};User ID=${d.name};Password=${loginPasswords[d.name]};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
    )
  }
}

module appService 'modules/appservice.bicep' = if (!empty(appServiceDeployables)) {
  name: 'appservice-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: appLocation
    tags: tags
    deployables: appServiceDeployables
    versions: versions
    identityResourceIds: [for (d, i) in appServiceDeployables: loginIdentities[i].id]
    connectionStringSecretUris: vault.outputs.loginConnectionStringUris
  }
}

module apps 'modules/containerapps.bicep' = {
  name: 'apps-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    managedEnvironmentName: managedEnvironmentName
    appCpu: string(environment.appCpu)
    location: appLocation
    tags: tags
    deployables: containerDeployables
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
output deployables array = concat(apps.outputs.deployables, empty(appServiceDeployables) ? [] : appService!.outputs.deployables)
output capabilities array = capabilities

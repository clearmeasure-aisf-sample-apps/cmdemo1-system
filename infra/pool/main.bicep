// Desired state of the pull-request slot pool. Applied as deployment stack stack-<slug>-pool in the nonprod
// resource group, only after Jeffrey's explicit yes (issue #653). Never by scripts/apply-environment.ps1, never by
// a pipeline that auto-applies: writing and merging this code is fine; creating the live Azure resources is not,
// until that yes is recorded.
//
// Contents: one Standard 50 eDTU elastic pool; template database sqldb-<slug>-pool-template; eight slot apps and
// databases pool-1 .. pool-8 (2 warm for shadow mode); private storage for videos and traces with 14-day expiry.
targetScope = 'resourceGroup'

@description('SQL administrator password for the pool server. The operator supplies it on the first manual apply.')
@secure()
param sqlAdminPassword string

@description('Principal ID of the nonprod deploy identity; it may read and write the pool vault and own the stack.')
param deployPrincipalId string

@description('Include private storage for videos and traces (14-day expiry). Default true; still not created live until Jeffrey says yes to apply this stack.')
param includeArtifactsStorage bool = true

var system = loadJsonContent('../../system.json')
var slug = system.system.slug
var location = system.system.location
var sqlLocation = union({ sqlLocation: location }, system.system).sqlLocation
var registryServer = union({ registry: { loginServer: '' } }, system.azure).registry.loginServer
var poolDefaults = {
  slots: 8
  warm: 2
  elasticPoolEdtus: 50
  appCpu: '1'
  maxReplicas: 3
  httpConcurrentRequests: 10
  artifactsRetentionDays: 14
}
var pool = union(poolDefaults, union({ pool: {} }, system).pool)
var slotCount = int(pool.slots)
var configuredWarm = int(pool.warm)
var slots = [for i in range(1, slotCount): 'pool-${i}']
var suffix = take(uniqueString(subscription().id, resourceGroup().id, 'pool'), 5)
var sqlSuffix = sqlLocation == location ? suffix : take(uniqueString(subscription().id, resourceGroup().id, 'pool', sqlLocation), 5)
var tags = {
  system: slug
  environment: 'pool'
  tier: 'nonprod'
  purpose: 'pr-slots'
}
var sqlServerName = 'sql-${slug}-pool-${sqlSuffix}'
var elasticPoolName = 'sqlep-${slug}-pool'
var templateDatabaseName = 'sqldb-${slug}-pool-template'
var sqlAdminLogin = 'sqladmin'
var sqlServerFqdn = '${sqlServerName}${az.environment().suffixes.sqlServerHostname}'
var vaultName = take('kv${slug}pool${suffix}', 24)
var ui = first(filter(system.deployables, d => d.name == 'ui'))!
var uiPort = int(ui.port)
var uiHealthPath = string(ui.healthPath)
resource poolAppIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-pool-app'
  location: location
  tags: tags
}

module sql 'modules/sql.bicep' = {
  name: 'pool-sql'
  params: {
    slug: slug
    serverName: sqlServerName
    elasticPoolName: elasticPoolName
    templateDatabaseName: templateDatabaseName
    location: sqlLocation
    tags: tags
    administratorLogin: sqlAdminLogin
    administratorPassword: sqlAdminPassword
    slots: slots
    elasticPoolCapacity: int(pool.elasticPoolEdtus)
  }
}

module vault 'modules/vault.bicep' = {
  name: 'pool-vault'
  params: {
    name: vaultName
    location: location
    tags: tags
    readerPrincipalIds: [
      poolAppIdentity.properties.principalId
    ]
    officerPrincipalIds: [
      deployPrincipalId
    ]
    slots: slots
    sqlAdminPassword: sqlAdminPassword
    templateConnectionString: 'Server=tcp:${sqlServerFqdn},1433;Database=${templateDatabaseName};User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
    slotConnectionStrings: reduce(
      slots,
      {},
      (acc, slot) => union(acc, {
        '${slot}': 'Server=tcp:${sqlServerFqdn},1433;Database=sqldb-${slug}-${slot};User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
      })
    )
  }
}

module slotApps 'modules/slots.bicep' = {
  name: 'pool-slots'
  params: {
    slug: slug
    location: location
    tags: tags
    slots: slots
    warmSlots: configuredWarm
    cpu: string(pool.appCpu)
    maxReplicas: int(pool.maxReplicas)
    httpConcurrentRequests: int(pool.httpConcurrentRequests)
    registryServer: registryServer
    identityResourceId: poolAppIdentity.id
    port: uiPort
    healthPath: uiHealthPath
    connectionStringSecretUris: vault.outputs.slotConnectionStringSecretUris
  }
}

module artifacts 'modules/artifacts.bicep' = if (includeArtifactsStorage) {
  name: 'pool-artifacts'
  params: {
    slug: slug
    location: location
    tags: tags
    readerPrincipalId: poolAppIdentity.properties.principalId
    retentionDays: int(pool.artifactsRetentionDays)
  }
}

output stackName string = 'stack-${slug}-pool'
output sqlServerName string = sql.outputs.serverName
output sqlServerFqdn string = sql.outputs.serverFqdn
output elasticPoolName string = sql.outputs.elasticPoolName
output templateDatabaseName string = sql.outputs.templateDatabaseName
output slotDatabases array = sql.outputs.slotDatabases
output slots array = slotApps.outputs.slots
output warmSlots int = configuredWarm
output keyVaultName string = vault.outputs.vaultName
output poolAppIdentityName string = poolAppIdentity.name
output poolAppIdentityPrincipalId string = poolAppIdentity.properties.principalId
output artifactsStorageAccountName string = includeArtifactsStorage ? artifacts!.outputs.storageAccountName : ''
output artifactsContainers array = includeArtifactsStorage ? artifacts!.outputs.containers : []
output artifactsRetentionDays int = includeArtifactsStorage ? artifacts!.outputs.retentionDays : 0

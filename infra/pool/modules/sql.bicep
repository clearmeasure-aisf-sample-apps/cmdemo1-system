// Pull-request pool SQL: one logical server, one Standard 50 eDTU elastic pool, the template database
// sqldb-<slug>-pool-template, and one database per slot (sqldb-<slug>-pool-1 .. pool-N). Every database
// sits in the elastic pool so a slot reset can copy from the template inside the pool.
targetScope = 'resourceGroup'

param slug string
param serverName string
param elasticPoolName string
param templateDatabaseName string
param location string
param tags object
param administratorLogin string
@secure()
param administratorPassword string

@description('Slot names such as pool-1 .. pool-8; each gets database sqldb-<slug>-<slot>.')
param slots array

@description('eDTUs of the Standard elastic pool (50 in shadow mode).')
@minValue(50)
@maxValue(100)
param elasticPoolCapacity int = 50

// Standard 50: 50 GB pool max size; each database may use up to the pool's eDTUs.
var poolMaxSizeBytes = 53687091200

resource server 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    administratorLogin: administratorLogin
    administratorLoginPassword: administratorPassword
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
  }
}

resource azureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01' = {
  parent: server
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

resource elasticPool 'Microsoft.Sql/servers/elasticPools@2023-08-01' = {
  parent: server
  name: elasticPoolName
  location: location
  tags: tags
  sku: {
    name: 'StandardPool'
    tier: 'Standard'
    capacity: elasticPoolCapacity
  }
  properties: {
    maxSizeBytes: poolMaxSizeBytes
    perDatabaseSettings: {
      minCapacity: 0
      maxCapacity: elasticPoolCapacity
    }
  }
}

resource templateDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: server
  name: templateDatabaseName
  location: location
  tags: union(tags, { role: 'template' })
  sku: {
    name: 'ElasticPool'
    tier: 'Standard'
  }
  properties: {
    elasticPoolId: elasticPool.id
    maxSizeBytes: poolMaxSizeBytes
  }
}

resource slotDatabases 'Microsoft.Sql/servers/databases@2023-08-01' = [
  for slot in slots: {
    parent: server
    name: 'sqldb-${slug}-${slot}'
    location: location
    tags: union(tags, { slot: slot, role: 'slot' })
    sku: {
      name: 'ElasticPool'
      tier: 'Standard'
    }
    properties: {
      elasticPoolId: elasticPool.id
      maxSizeBytes: poolMaxSizeBytes
    }
  }
]

output serverName string = server.name
output serverFqdn string = server.properties.fullyQualifiedDomainName
output elasticPoolName string = elasticPool.name
output templateDatabaseName string = templateDatabase.name
output slotDatabases array = [
  for (slot, i) in slots: {
    slot: slot
    databaseName: slotDatabases[i].name
  }
]

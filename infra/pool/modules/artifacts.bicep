// Private Azure storage for pull-request videos and traces. Lifecycle deletes blobs 14 days after last
// modification. Code only until Jeffrey says yes to create the live account (issue #653).
targetScope = 'resourceGroup'

param slug string
param location string
param tags object

@description('Principal ID of the pool slot app identity: Storage Blob Data Contributor on each container.')
param readerPrincipalId string

@description('Days after last modification before a blob is deleted.')
@minValue(1)
@maxValue(365)
param retentionDays int = 14

var accountName = take(toLower('st${slug}poolart${uniqueString(resourceGroup().id)}'), 24)
var blobDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
var containers = [
  'videos'
  'traces'
]

resource account 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: accountName
  location: location
  tags: union(tags, { purpose: 'pool-artifacts' })
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = {
  parent: account
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: retentionDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: retentionDays
    }
  }
}

resource artifactContainers 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = [
  for name in containers: {
    parent: blobs
    name: name
    properties: {
      publicAccess: 'None'
    }
  }
]

resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2024-01-01' = {
  parent: account
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          enabled: true
          name: 'expire-videos-and-traces'
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: [
                'blockBlob'
              ]
              prefixMatch: [
                'videos/'
                'traces/'
              ]
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: retentionDays
                }
              }
            }
          }
        }
      ]
    }
  }
}

resource access 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (name, i) in containers: {
    name: guid(artifactContainers[i].id, readerPrincipalId, blobDataContributor)
    scope: artifactContainers[i]
    properties: {
      principalId: readerPrincipalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: blobDataContributor
    }
  }
]

output storageAccountName string = account.name
output blobEndpoint string = account.properties.primaryEndpoints.blob
output containers array = containers
output retentionDays int = retentionDays

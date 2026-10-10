// Catalog entry "blob-store": a private blob container for one container deployable, which reads and writes it as its
// own identity (no key, no connection string). Copy this file over the system's infra/own/main.bicep, or take its
// resources into the file the system already has there; from then on it is the system's file (README.md beside this
// file: what it costs, its limits, and the checks that go with it).
targetScope = 'resourceGroup'

@description('The environment this runs in, from ../main.bicep: the system\'s slug, the environment\'s name, the system\'s region, the tags of every resource, and the identity of each container deployable that has one of its own (one that declares secrets in system.json): its name, and the principal ID, client ID and resource ID of id-<slug>-<env>-<deployable>.')
param stack {
  slug: string
  environmentName: string
  location: string
  tags: object
  identities: {
    deployable: string
    principalId: string
    clientId: string
    resourceId: string
  }[]
}

// The system's choices: the deployable that gets the store, the container's name, the names of the two settings the
// app reads, and how many days a deleted or overwritten blob can be brought back.
var deployable = 'scorecard'
var containerName = deployable
var containerUriSetting = 'Scorecard__Storage__ContainerUri'
var clientIdSetting = 'Scorecard__Storage__ManagedIdentityClientId'
var softDeleteDays = 7

// The store exists in the environments in which the deployable exists and has an identity of its own.
var identity = first(filter(stack.identities, i => i.deployable == deployable)) ?? {
  deployable: ''
  principalId: ''
  clientId: ''
  resourceId: ''
}
var hasStore = !empty(identity.deployable)
// 3 to 24 lower-case letters and digits, unique in Azure: the hash is of the resource group.
var accountName = take(toLower('st${stack.slug}${stack.environmentName}${uniqueString(resourceGroup().id)}'), 24)
// Storage Blob Data Contributor: read, write and delete blobs; no key, no account setting.
var blobDataContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')

resource account 'Microsoft.Storage/storageAccounts@2024-01-01' = if (hasStore) {
  name: accountName
  location: stack.location
  tags: stack.tags
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

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = if (hasStore) {
  parent: account
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: softDeleteDays
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: softDeleteDays
    }
  }
}

resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = if (hasStore) {
  parent: blobs
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// On the container, not the account: the deployable reads and writes its own container and nothing else.
resource access 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasStore) {
  scope: container
  name: guid(container.id, deployable, blobDataContributor)
  properties: {
    principalId: identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobDataContributor
  }
}

@description('Settings for container deployables, by deployable and then by name: { "<deployable>": { "<NAME>": "<value>" } }. Each becomes an environment variable of that deployable\'s container app. Never a secret: a value here is readable in the deployment.')
output settings object = hasStore
  ? {
      '${deployable}': {
        '${containerUriSetting}': '${account!.properties.primaryEndpoints.blob}${containerName}'
        '${clientIdSetting}': identity.clientId
      }
    }
  : {}

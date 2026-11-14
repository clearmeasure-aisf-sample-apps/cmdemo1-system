// Vault of the pull-request pool: SQL administrator password, the template connection string, and one
// connection string per slot. The pool app identity reads them; the deploy identity reads and writes.
targetScope = 'resourceGroup'

param name string
param location string
param tags object
param readerPrincipalIds array
param officerPrincipalIds array
param slots array
@secure()
param sqlAdminPassword string
@secure()
param templateConnectionString string
@secure()
param slotConnectionStrings object

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    tenantId: tenant().tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

resource readers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in readerPrincipalIds: {
    name: guid(vault.id, principalId, 'secrets-user')
    scope: vault
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    }
  }
]

resource officers 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in officerPrincipalIds: {
    name: guid(vault.id, principalId, 'secrets-officer')
    scope: vault
    properties: {
      principalId: principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7')
    }
  }
]

resource sqlPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'sql-admin-password'
  properties: {
    value: sqlAdminPassword
  }
}

resource templateSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'sql-connection-string-template'
  properties: {
    value: templateConnectionString
  }
}

resource slotSecrets 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for slot in slots: {
    parent: vault
    name: 'sql-connection-string-${slot}'
    properties: {
      value: slotConnectionStrings[slot]
    }
  }
]

output vaultUri string = vault.properties.vaultUri
output vaultName string = vault.name
// Versionless URIs: Container Apps pick up a rotated value without a new revision.
output templateConnectionStringSecretUri string = '${vault.properties.vaultUri}secrets/sql-connection-string-template'
output slotConnectionStringSecretUris object = reduce(
  slots,
  {},
  (acc, slot) => union(acc, { '${slot}': '${vault.properties.vaultUri}secrets/sql-connection-string-${slot}' })
)

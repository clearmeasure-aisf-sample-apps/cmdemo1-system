// Capability "baseline": the environment's vault (RBAC authorization, no purge protection so a torn-down demo can be
// purged) with the SQL secrets. The runtime identity reads secrets; the deploy identity reads and writes them.
targetScope = 'resourceGroup'

param name string
param location string
param tags object
param readerPrincipalIds array
param officerPrincipalIds array
@secure()
param sqlAdminPassword string
@secure()
param sqlConnectionString string

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

resource adminPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'sql-admin-password'
  properties: {
    value: sqlAdminPassword
    contentType: 'text/plain'
  }
}

resource connectionString 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'sql-connection-string'
  properties: {
    value: sqlConnectionString
    contentType: 'text/plain'
  }
  dependsOn: [
    readers
  ]
}

output name string = vault.name
// Versionless URI: the container app picks up a rotated value without a new revision.
output connectionStringSecretUri string = '${vault.properties.vaultUri}secrets/${connectionString.name}'

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

@description('Database logins of App Service deployables: name, and the principal ID of the one identity that may read its connection string.')
param logins array = []
@description('Password of each login, by name.')
@secure()
param loginPasswords object = {}
@description('Connection string of each login, by name.')
@secure()
param loginConnectionStrings object = {}

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

// A login's password (read by the deploy identity's grant step) and its connection string, which only the
// deployable's own identity may read: the role is assigned on the secret, not on the vault.
resource loginPassword 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for l in logins: {
    parent: vault
    name: '${l.name}-sql-password'
    properties: {
      value: loginPasswords[l.name]
      contentType: 'text/plain'
    }
  }
]

resource loginConnectionString 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = [
  for l in logins: {
    parent: vault
    name: '${l.name}-sql-connection-string'
    properties: {
      value: loginConnectionStrings[l.name]
      contentType: 'text/plain'
    }
  }
]

resource loginReaders 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for (l, i) in logins: {
    // A role assignment cannot change its principal, and an identity, role and scope allow only one assignment. So the
    // assignment keeps its name while the identity keeps its name, and an identity that placement renamed (a moved
    // environment: a new principal) gets an assignment of its own, next to the old one, which the stack then removes.
    name: empty(l.renamedIdentity) ? guid(vault.id, l.name, 'login-secret-user') : guid(vault.id, l.name, l.renamedIdentity, 'login-secret-user')
    scope: loginConnectionString[i]
    properties: {
      principalId: l.principalId
      principalType: 'ServicePrincipal'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '4633458b-17de-408a-b874-0445c86b69e6')
    }
  }
]

output name string = vault.name
output loginConnectionStringUris array = [
  for (l, i) in logins: '${vault.properties.vaultUri}secrets/${loginConnectionString[i].name}'
]
// Versionless URI: the container app picks up a rotated value without a new revision.
output connectionStringSecretUri string = '${vault.properties.vaultUri}secrets/${connectionString.name}'

// The nonprod group of the seed: the shared registry, the Terraform state account of octopus/, the identities of the
// GitHub workflows (plan, octopus-config, acr-push), and the nonprod tier (seed-tier.bicep).
targetScope = 'resourceGroup'

param slug string
param location string
param tags object
param githubIssuer string
param octopusIssuer string
param audience string
param planSubject string
param octopusConfigSubject string
param acrPushSubjects array
param deploySubjects array
param appEnvironments array

var suffix = take(uniqueString(resourceGroup().id, slug), 6)

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: 'acr${slug}${suffix}'
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource state 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: 'st${slug}tf${suffix}'
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource blobs 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: state
  name: 'default'
}

resource stateContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobs
  name: 'tfstate'
}

// The plan identity: what-if previews of pull requests and the nightly drift check (Reader).
resource plan 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-plan'
  location: location
  tags: tags
}

resource planCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: plan
  name: 'github-azure-read'
  properties: {
    issuer: githubIssuer
    subject: planSubject
    audiences: [audience]
  }
}

module planReader 'role-assignment.bicep' = {
  name: 'seed-${slug}-nonprod-reader'
  params: {
    principalId: plan.properties.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    description: 'id-${slug}-plan: what-if previews and drift checks of nonprod'
  }
}

// The octopus-config identity: the Terraform state of octopus/ only (Storage Blob Data Contributor on the account).
resource octopusConfig 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-octopus-config'
  location: location
  tags: tags
}

resource octopusConfigCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: octopusConfig
  name: 'github-octopus'
  properties: {
    issuer: githubIssuer
    subject: octopusConfigSubject
    audiences: [audience]
  }
}

resource stateWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(state.id, octopusConfig.id, 'blob-data-contributor')
  scope: state
  properties: {
    principalId: octopusConfig.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    description: 'id-${slug}-octopus-config: Terraform state of octopus/'
  }
}

// The acr-push identity: the release workflows of the app repositories push images (AcrPush on the registry).
resource acrPush 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${slug}-acr-push'
  location: location
  tags: tags
}

@batchSize(1)
resource acrPushCredentials 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [
  for (subject, i) in acrPushSubjects: {
    parent: acrPush
    name: 'github-release-${i}'
    properties: {
      issuer: githubIssuer
      subject: subject
      audiences: [audience]
    }
  }
]

resource acrPusher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, acrPush.id, 'acrpush')
  scope: registry
  properties: {
    principalId: acrPush.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '8311e382-0749-4cb8-b61a-304f252e45ec')
    description: 'id-${slug}-acr-push: release workflows of the app repositories'
  }
}

module tier 'seed-tier.bicep' = {
  name: 'seed-${slug}-nonprod-tier'
  params: {
    slug: slug
    tier: 'nonprod'
    location: location
    tags: tags
    octopusIssuer: octopusIssuer
    audience: audience
    deploySubjects: deploySubjects
    appEnvironments: appEnvironments
  }
}

module nonprodAcrPull 'registry-pull.bicep' = {
  name: 'seed-${slug}-nonprod-acr-pull'
  params: {
    registryName: registry.name
    principalIds: map(tier.outputs.apps, a => a.principalId)
  }
}

output registry object = {
  name: registry.name
  loginServer: registry.properties.loginServer
}

output terraformState object = {
  resourceGroup: resourceGroup().name
  storageAccount: state.name
  container: stateContainer.name
}

output plan object = {
  name: plan.name
  clientId: plan.properties.clientId
  principalId: plan.properties.principalId
}

output octopusConfig object = {
  name: octopusConfig.name
  clientId: octopusConfig.properties.clientId
  principalId: octopusConfig.properties.principalId
}

output acrPush object = {
  name: acrPush.name
  clientId: acrPush.properties.clientId
  principalId: acrPush.properties.principalId
}

output deploy object = tier.outputs.deploy
output apps array = tier.outputs.apps

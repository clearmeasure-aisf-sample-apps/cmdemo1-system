// Catalog entry "blob-store": a private blob container for one container deployable, which reads and writes it as its
// own identity (no key, no connection string). Copy this file over the system's infra/own/main.bicep, or take its
// resources into the file the system already has there; from then on it is the system's file (README.md beside this
// file: what it costs, its limits, and the checks that go with it).
//
// Issue #542 (2026-11-10): aisf, fworker, fwrunner, Foundry aif-cmdemo1-*, the fworker SQL database, and the factory
// incident alerts/action groups left this template. Deployment stacks apply with --action-on-unmanage deleteResources,
// so the next system deploy in each environment deletes those unmanaged resources. ui, dashboard, scorecard and the
// prod space-scorecard site stay.
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

// The store exists in the environments in which the deployable exists and has an identity of its own. Since
// scorecard is retired (system.json deployables[].retired, decision 0058; its pages are on GitHub Pages) it has no
// identity anywhere, so hasStore is false and the stack removes the store with its app: what it held was the app's
// raw harvest, which a harvest makes again.
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

var system = loadJsonContent('../../system.json')

// Space-level scorecard site in prod (design "Space-level scorecard on cmis"): public blob containers of a storage
// account in prod, which the nightly runbook "Refresh space scorecard" of each such space (Octopus project
// <prefix>-scorecard-space of its space, environment prod) writes. cmdemo1's own pages left it for private GitHub
// Pages in step 5 (repository clearmeasure-aisf-sample-apps/cmdemo1-scorecard-site), with them its container
// "scorecard" and the federated credential of <slug>-scorecard-space.
// A public blob container, not a static website: ARM has no static website setting, and under the stack's deny
// settings only the deploy identity could switch it on, which no step of the system's deployment does for a resource
// of infra/own. Anonymous reads of single blobs only: a container cannot be listed.
// The runbooks sign in as an identity of their own (an Octopus Azure OpenID Connect account <prefix>-scorecard-site
// that space-scorecard/setup-octopus.ps1 makes), not as the deploy identity: a runbook runs the code of whatever branch
// a manual run names, so the identity may write the site's containers and nothing else.
var hasScorecardSite = stack.environmentName == 'prod'
var scorecardSiteName = take(toLower('st${stack.slug}${stack.environmentName}ssc${uniqueString(resourceGroup().id)}'), 24)
var scorecardSiteTags = union(stack.tags, { purpose: 'space-scorecard' })
// The demo spaces whose scorecard this site publishes (step 4 of the design): each a container of its own,
// scorecard-<prefix>, which the identity writes for runs of project <prefix>-scorecard-space of that space's prod
// (space-scorecard/<prefix>.json, site.container). Their Azure stacks are their systems'; this site is cmdemo1's.
var scorecardSiteSpaces = loadJsonContent('scorecard-site-spaces.json')

resource scorecardSite 'Microsoft.Storage/storageAccounts@2024-01-01' = if (hasScorecardSite) {
  name: scorecardSiteName
  location: stack.location
  tags: scorecardSiteTags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    // Needed for the containers' anonymous reads below; no other container is in this account.
    allowBlobPublicAccess: true
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}

resource scorecardSiteBlobs 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = if (hasScorecardSite) {
  parent: scorecardSite
  name: 'default'
}

resource scorecardSiteIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (hasScorecardSite) {
  name: 'id-${stack.slug}-${stack.environmentName}-scorecard-site'
  location: stack.location
  tags: scorecardSiteTags
}

// Each space's pages: its own public container, a federated credential for its runbook's runs, the same writer role.
resource scorecardSpacePages 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = [for s in scorecardSiteSpaces: if (hasScorecardSite) {
  parent: scorecardSiteBlobs
  name: 'scorecard-${s.prefix}'
  properties: {
    publicAccess: 'Blob'
  }
}]

// One at a time: Azure refuses concurrent writes of federated credentials of one identity.
@batchSize(1)
resource scorecardSpaceOctopus 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = [for s in scorecardSiteSpaces: if (hasScorecardSite) {
  parent: scorecardSiteIdentity
  name: 'octopus-scorecard-space-${s.prefix}'
  properties: {
    issuer: system.octopus.url
    subject: 'space:${s.spaceSlug}:project:${s.prefix}-scorecard-space:environment:${stack.environmentName}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}]

resource scorecardSpaceWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = [for (s, i) in scorecardSiteSpaces: if (hasScorecardSite) {
  scope: scorecardSpacePages[i]
  name: guid(scorecardSpacePages[i].id, 'scorecard-site', blobDataContributor)
  properties: {
    principalId: scorecardSiteIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobDataContributor
  }
}]

@description('Settings for container deployables, by deployable and then by name: { "<deployable>": { "<NAME>": "<value>" } }. Each becomes an environment variable of that deployable\'s container app. Never a secret: a value here is readable in the deployment.')
output settings object = hasStore
  ? {
      '${deployable}': {
        '${containerUriSetting}': '${account!.properties.primaryEndpoints.blob}${containerName}'
        '${clientIdSetting}': identity.clientId
      }
    }
  : {}

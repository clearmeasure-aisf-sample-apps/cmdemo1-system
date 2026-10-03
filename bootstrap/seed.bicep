// Seed of a demo system (layer 0): the two resource groups, the shared registry, the Terraform state account for the
// Octopus configuration, and every identity the pipelines sign in as, with their federated credentials and grants.
// Applied once by the operator as subscription Owner (the demo-environment skill, new-demo-seed.ps1):
//   az deployment sub create --location <region> --template-file bootstrap/seed.bicep --parameters @<file>
// Nothing else creates identities or role assignments outside a resource group; every later Azure change goes through
// the pipelines (infra/, applied by Octopus). Federated credentials exist for every environment from the start, so
// adding uat or prod later is a pull request, not a re-run of the seed.
targetScope = 'subscription'

@description('System slug: 3 to 10 lowercase letters and digits, starting with a letter. Every name derives from it.')
@minLength(3)
@maxLength(10)
param slug string

@description('Azure region of every resource of the system.')
param location string

param nonprodResourceGroupName string
param prodResourceGroupName string

@description('GitHub organization that owns the system and app repositories.')
param githubOrg string

@description('Name of the system (GitOps) repository.')
param systemRepository string

@description('Names of the app repositories whose release workflow pushes images (environment "release").')
param appRepositories array

@description('Octopus server URL without a trailing slash; it is the OIDC issuer of the Octopus Azure accounts.')
param octopusUrl string

@description('Slug of the Octopus space that holds the system projects.')
param octopusSpaceSlug string

@description('Slugs of the Octopus projects that sign in to Azure: <slug>-system and one per deployable.')
param octopusProjectSlugs array

@description('Every environment the system may ever have, with its tier: [{ name: "tdd", tier: "nonprod" }, ...].')
param environments array

param tags object = {}

var githubIssuer = 'https://token.actions.githubusercontent.com'
var audience = 'api://AzureADTokenExchange'
var nonprodEnvironments = filter(environments, e => e.tier == 'nonprod')
var prodEnvironments = filter(environments, e => e.tier == 'prod')
var allTags = union(tags, { system: slug, purpose: 'demo' })

resource nonprodGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: nonprodResourceGroupName
  location: location
  tags: union(allTags, { tier: 'nonprod' })
}

resource prodGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: prodResourceGroupName
  location: location
  tags: union(allTags, { tier: 'prod' })
}

// Nonprod group: the registry, the state account, the identities of the pipelines and of tdd and uat.
module nonprod 'modules/seed-nonprod.bicep' = {
  name: 'seed-${slug}-nonprod'
  scope: nonprodGroup
  params: {
    slug: slug
    location: location
    tags: union(allTags, { tier: 'nonprod' })
    githubIssuer: githubIssuer
    octopusIssuer: octopusUrl
    audience: audience
    planSubject: 'repo:${githubOrg}/${systemRepository}:environment:azure-read'
    octopusConfigSubject: 'repo:${githubOrg}/${systemRepository}:environment:octopus'
    acrPushSubjects: [for repository in appRepositories: 'repo:${githubOrg}/${repository}:environment:release']
    deploySubjects: flatten(map(nonprodEnvironments, e => map(octopusProjectSlugs, p => 'space:${octopusSpaceSlug}:project:${p}:environment:${e.name}')))
    appEnvironments: map(nonprodEnvironments, e => e.name)
  }
}

// Prod group: the deploy identity of prod and the runtime identity of each prod environment.
module prod 'modules/seed-tier.bicep' = {
  name: 'seed-${slug}-prod'
  scope: prodGroup
  params: {
    slug: slug
    tier: 'prod'
    location: location
    tags: union(allTags, { tier: 'prod' })
    octopusIssuer: octopusUrl
    audience: audience
    deploySubjects: flatten(map(prodEnvironments, e => map(octopusProjectSlugs, p => 'space:${octopusSpaceSlug}:project:${p}:environment:${e.name}')))
    appEnvironments: map(prodEnvironments, e => e.name)
  }
}

// Cross-group grants: the plan identity reads prod, and prod's runtime identities pull from the registry in nonprod.
module prodReader 'modules/role-assignment.bicep' = {
  name: 'seed-${slug}-prod-reader'
  scope: prodGroup
  params: {
    principalId: nonprod.outputs.plan.principalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    description: 'id-${slug}-plan: what-if previews and drift checks of prod'
  }
}

module prodAcrPull 'modules/registry-pull.bicep' = {
  name: 'seed-${slug}-prod-acr-pull'
  scope: nonprodGroup
  params: {
    registryName: nonprod.outputs.registry.name
    principalIds: map(prod.outputs.apps, a => a.principalId)
  }
}

output subscriptionId string = subscription().subscriptionId
output tenantId string = tenant().tenantId
output resourceGroups object = {
  nonprod: nonprodGroup.name
  prod: prodGroup.name
}
output registry object = nonprod.outputs.registry
output terraformState object = nonprod.outputs.terraformState
output identities object = {
  plan: nonprod.outputs.plan
  octopusConfig: nonprod.outputs.octopusConfig
  acrPush: nonprod.outputs.acrPush
  deploy: {
    nonprod: nonprod.outputs.deploy
    prod: prod.outputs.deploy
  }
  apps: concat(nonprod.outputs.apps, prod.outputs.apps)
}

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

// Cloud worker runtime of the factory worker (cmdemo1-fworker docs/design/cloud-worker-runtimes.md, sections 2, 3 and 6):
// Container Apps jobs, each execution of which runs one work item, as an identity of its own (no key anywhere): one with
// Claude Code on a Foundry deployment of Claude, one with Codex CLI on an OpenAI deployment. In the environments below:
// tdd since 2026-10-15 (rollout step 2), uat and prod since 2026-10-16 (steps 5 and 6, Jeffrey: "Implement all phases").
// prod follows once its Container Apps environment has the D4 profile (one release earlier).
var runnerEnvironments = ['tdd', 'uat']
var hasRunner = contains(runnerEnvironments, stack.environmentName)
var runnerDeployment = 'claude-sonnet-5-5'
// Off until Azure Marketplace lets the subscription buy the Anthropic offer: the first deployment failed with
// MarketplaceSubscriptionCannotBeCompleted (the subscription needs Microsoft's allowlisting), and a failing resource
// would fail every deployment of the environment.
var deploysClaude = false
// The model of the Codex worker (Jeffrey, 2026-10-15).
var codexDeployment = 'gpt-6.1-sol'
// The dedicated workload profile of the Container Apps environment the jobs run on (../modules/containerapps.bicep,
// cmdemo1's own copy, gives tdd, which uat shares, and prod a D4 profile of zero to two nodes).
var runnerWorkloadProfile = 'D4'
// The runner image of cmdemo1-fworker (release.yml of pull request #150): Claude Code and Codex CLI in one image; the
// job's FWRUNNER_AGENT chooses. Its own entry point runs the work item the gateway hands over.
var system = loadJsonContent('../../system.json')
var runnerImage = '${system.azure.registry.loginServer}/cmdemo1/fwrunner:2.1.300-263'
// The Container Apps environment the apps of this environment run in, named as ../main.bicep names it
// (managedEnvironmentName; cmdemo1 has no azure.appEnvironment): uat runs in tdd's, prod in its own with a region suffix.
var runnerEnvironment = first(filter(system.environments, e => e.name == stack.environmentName))!
var runnerSharedWith = string(union({ sharesAppEnvironmentWith: '' }, runnerEnvironment).sharesAppEnvironmentWith)
var runnerHost = empty(runnerSharedWith) ? runnerEnvironment : first(filter(system.environments, e => e.name == runnerSharedWith))!
var runnerLocation = string(union({ appLocation: stack.location }, runnerHost).appLocation)
var runnerPlacement = contains(runnerHost, 'appLocation') ? '-${take(uniqueString(runnerLocation), 4)}' : ''
// The registry is in the nonprod group (the seed's). There the runner pulls as itself (AcrPull below); in prod, whose
// deploy identity has no right in the nonprod group, the job pulls as the environment's shared identity, which the seed
// gave AcrPull, and which the containers cannot use (identitySettings, lifecycle None), as the kit does for the apps.
var registryInThisGroup = resourceGroup().name == system.azure.resourceGroups.nonprod
var sharedIdentityId = first(filter(system.azure.identities.apps, a => a.environment == stack.environmentName))!.resourceId
var gateway = first(filter(stack.identities, i => i.deployable == 'fworker')) ?? {
  deployable: ''
  principalId: ''
  clientId: ''
  resourceId: ''
}
var runnerStoreName = take(toLower('st${stack.slug}${stack.environmentName}fwr${uniqueString(resourceGroup().id)}'), 24)
var runnerTags = union(stack.tags, { purpose: 'fwrunner' })
var acrPull = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
// Foundry User (formerly Azure AI User): call the account's model deployments.
var foundryUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '53ca6127-db72-4b80-b1b0-d745d6d5456d')

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (hasRunner && registryInThisGroup) {
  name: system.azure.registry.name
}

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (hasRunner) {
  name: 'cae-${stack.slug}-${runnerHost.name}${runnerPlacement}'
}

resource runnerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (hasRunner) {
  name: 'id-${stack.slug}-${stack.environmentName}-fwrunner'
  location: stack.location
  tags: runnerTags
}

resource foundry 'Microsoft.CognitiveServices/accounts@2025-06-01' = if (hasRunner) {
  name: 'aif-${stack.slug}-${stack.environmentName}'
  location: stack.location
  tags: runnerTags
  kind: 'AIServices'
  sku: {
    name: 'S0'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    customSubDomainName: 'aif-${stack.slug}-${stack.environmentName}'
    allowProjectManagement: true
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
  }
}

// Billed through Azure Marketplace; capacity is in thousands of tokens per minute. An Anthropic model needs the
// organization's details (modelProviderData), which the 2025-10-01-preview API accepts.
resource claude 'Microsoft.CognitiveServices/accounts/deployments@2025-10-01-preview' = if (hasRunner && deploysClaude) {
  parent: foundry
  name: runnerDeployment
  sku: {
    name: 'GlobalStandard'
    capacity: 600
  }
  properties: {
    model: {
      format: 'Anthropic'
      name: runnerDeployment
      version: '2'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
    #disable-next-line BCP037
    modelProviderData: {
      industry: 'Technology'
      organizationName: 'Clear Measure'
      countryCode: 'US'
    }
  }
}

// The model of the Codex worker: an OpenAI model is sold by Microsoft itself, no Marketplace purchase.
resource sol 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (hasRunner) {
  parent: foundry
  name: codexDeployment
  // One deployment operation at a time per account.
  dependsOn: [
    claude
  ]
  sku: {
    name: 'GlobalStandard'
    capacity: 600
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: codexDeployment
      version: '2026-09-29'
    }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource runnerStore 'Microsoft.Storage/storageAccounts@2024-01-01' = if (hasRunner) {
  name: runnerStoreName
  location: stack.location
  tags: runnerTags
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

resource runnerBlobs 'Microsoft.Storage/storageAccounts/blobServices@2024-01-01' = if (hasRunner) {
  parent: runnerStore
  name: 'default'
}

resource transcripts 'Microsoft.Storage/storageAccounts/blobServices/containers@2024-01-01' = if (hasRunner) {
  parent: runnerBlobs
  name: 'fwrunner-transcripts'
  properties: {
    publicAccess: 'None'
  }
}

// A transcript is deleted 14 days after its last change.
resource transcriptLifetime 'Microsoft.Storage/storageAccounts/managementPolicies@2024-01-01' = if (hasRunner) {
  parent: runnerStore
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'fwrunner-transcripts-14-days'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob', 'appendBlob']
              prefixMatch: ['fwrunner-transcripts/']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterModificationGreaterThan: 14
                }
              }
            }
          }
        }
      ]
    }
  }
}

resource runnerPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasRunner && registryInThisGroup) {
  scope: registry
  name: guid(registry.id, 'fwrunner', stack.environmentName, acrPull)
  properties: {
    principalId: runnerIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPull
  }
}

resource runnerModel 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasRunner) {
  scope: foundry
  name: guid(foundry.id, 'fwrunner', foundryUser)
  properties: {
    principalId: runnerIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: foundryUser
  }
}

resource runnerTranscripts 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasRunner) {
  scope: transcripts
  name: guid(transcripts.id, 'fwrunner', blobDataContributor)
  properties: {
    principalId: runnerIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: blobDataContributor
  }
}

// One execution per work item, started by the gateway: no ingress, no retry, four hours at most.
// A job has no termination grace setting: the API refuses terminationGracePeriodSeconds in a job template.
resource runner 'Microsoft.App/jobs@2025-01-01' = if (hasRunner) {
  name: 'caj-${stack.slug}-${stack.environmentName}-fwrunner'
  location: runnerLocation
  tags: runnerTags
  dependsOn: [
    runnerPull
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: union({ '${runnerIdentity.id}': {} }, registryInThisGroup ? {} : { '${sharedIdentityId}': {} })
  }
  properties: {
    environmentId: managedEnvironment.id
    workloadProfileName: runnerWorkloadProfile
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 14400
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      ...(registryInThisGroup
        ? {}
        : {
            identitySettings: [
              {
                identity: sharedIdentityId
                lifecycle: 'None'
              }
            ]
          })
      registries: [
        {
          server: system.azure.registry.loginServer
          identity: registryInThisGroup ? runnerIdentity.id : sharedIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'fwrunner'
          image: runnerImage
          resources: {
            // A D4 node keeps part of its 4 vCPU for the platform: a 4-vCPU replica may never be scheduled.
            cpu: json('3.5')
            memory: '8Gi'
          }
          env: [
            { name: 'CLAUDE_CODE_USE_FOUNDRY', value: '1' }
            { name: 'ANTHROPIC_FOUNDRY_RESOURCE', value: foundry.name }
            { name: 'ANTHROPIC_DEFAULT_SONNET_MODEL', value: runnerDeployment }
            { name: 'ANTHROPIC_DEFAULT_OPUS_MODEL', value: runnerDeployment }
            { name: 'ANTHROPIC_DEFAULT_HAIKU_MODEL', value: runnerDeployment }
            { name: 'AZURE_CLIENT_ID', value: runnerIdentity!.properties.clientId }
          ]
        }
      ]
    }
  }
}

// The same runner with Codex CLI on the OpenAI deployment instead of Claude Code: same identity, limits and size.
resource codexRunner 'Microsoft.App/jobs@2025-01-01' = if (hasRunner) {
  name: 'caj-${stack.slug}-${stack.environmentName}-fwrunner-codex'
  location: runnerLocation
  tags: runnerTags
  dependsOn: [
    runnerPull
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: union({ '${runnerIdentity.id}': {} }, registryInThisGroup ? {} : { '${sharedIdentityId}': {} })
  }
  properties: {
    environmentId: managedEnvironment.id
    workloadProfileName: runnerWorkloadProfile
    configuration: {
      triggerType: 'Manual'
      replicaTimeout: 14400
      replicaRetryLimit: 0
      manualTriggerConfig: {
        parallelism: 1
        replicaCompletionCount: 1
      }
      ...(registryInThisGroup
        ? {}
        : {
            identitySettings: [
              {
                identity: sharedIdentityId
                lifecycle: 'None'
              }
            ]
          })
      registries: [
        {
          server: system.azure.registry.loginServer
          identity: registryInThisGroup ? runnerIdentity.id : sharedIdentityId
        }
      ]
    }
    template: {
      containers: [
        {
          name: 'fwrunner'
          image: runnerImage
          resources: {
            // A D4 node keeps part of its 4 vCPU for the platform: a 4-vCPU replica may never be scheduled.
            cpu: json('3.5')
            memory: '8Gi'
          }
          env: [
            { name: 'FWRUNNER_AGENT', value: 'codex' }
            { name: 'AZURE_OPENAI_ENDPOINT', value: 'https://${foundry.name}.openai.azure.com/' }
            { name: 'AZURE_OPENAI_DEPLOYMENT', value: codexDeployment }
            { name: 'AZURE_CLIENT_ID', value: runnerIdentity!.properties.clientId }
          ]
        }
      ]
    }
  }
}

// The gateway starts, follows and stops executions of the two jobs, and nothing else.
resource runnerOperator 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (hasRunner && !empty(gateway.deployable)) {
  name: guid(resourceGroup().id, 'fwrunner-operator', stack.environmentName)
  properties: {
    roleName: '${stack.slug} ${stack.environmentName} fwrunner job operator'
    description: 'Start, read and stop executions of the jobs caj-${stack.slug}-${stack.environmentName}-fwrunner and -fwrunner-codex.'
    type: 'CustomRole'
    permissions: [
      {
        actions: [
          'Microsoft.App/jobs/read'
          'Microsoft.App/jobs/start/action'
          'Microsoft.App/jobs/executions/read'
          'Microsoft.App/jobs/stop/action'
        ]
        notActions: []
      }
    ]
    assignableScopes: [
      runner.id
      codexRunner.id
    ]
  }
}

resource gatewayRunner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasRunner && !empty(gateway.deployable)) {
  scope: runner
  name: guid(runner.id, 'fworker', 'fwrunner-operator')
  properties: {
    principalId: gateway.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', runnerOperator.name)
  }
}

resource gatewayCodexRunner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasRunner && !empty(gateway.deployable)) {
  scope: codexRunner
  name: guid(codexRunner.id, 'fworker', 'fwrunner-operator')
  properties: {
    principalId: gateway.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', runnerOperator.name)
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

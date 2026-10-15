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

// Cloud worker runtime of the factory worker, phase 1 (cmdemo1-fworker docs/design/cloud-worker-runtimes.md, sections 2
// and 3): one Container Apps job, each execution of which runs one work item with Claude Code on a Foundry deployment
// of Claude, as an identity of its own (no key anywhere). Only in the environments below.
var runnerEnvironments = ['tdd']
var hasRunner = contains(runnerEnvironments, stack.environmentName)
var runnerDeployment = 'claude-sonnet-5-5'
// Off until Azure Marketplace lets the subscription buy the Anthropic offer: the first deployment failed with
// MarketplaceSubscriptionCannotBeCompleted (the subscription needs Microsoft's allowlisting), and a failing resource
// would fail every deployment of the environment.
var deploysClaude = false
// The workload profile of the Container Apps environment the job runs on: D4 once the environment has one (the kit's
// template creates the environment); until then Consumption, which also allows 4 vCPU and 8 GiB.
var runnerWorkloadProfile = 'Consumption'
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

resource registry 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = if (hasRunner) {
  name: loadJsonContent('../../system.json').azure.registry.name
}

// The environment's default name in this group: right while the environment has no appLocation of its own and the
// system no azure.appEnvironment (../main.bicep, managedEnvironmentName).
resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' existing = if (hasRunner) {
  name: 'cae-${stack.slug}-${stack.environmentName}'
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

resource runnerPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasRunner) {
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
resource runner 'Microsoft.App/jobs@2025-01-01' = if (hasRunner) {
  name: 'caj-${stack.slug}-${stack.environmentName}-fwrunner'
  location: stack.location
  tags: runnerTags
  dependsOn: [
    runnerPull
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${runnerIdentity.id}': {}
    }
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
      registries: [
        {
          server: registry!.properties.loginServer
          identity: runnerIdentity.id
        }
      ]
    }
    template: {
      // The job API takes it although the Bicep types do not list it yet.
      #disable-next-line BCP037
      terminationGracePeriodSeconds: 60
      containers: [
        {
          name: 'fwrunner'
          // A placeholder until the fwrunner image is in the registry (cmdemo1-fworker pull request #150).
          image: 'mcr.microsoft.com/azure-cli:latest'
          command: ['/bin/sh', '-c']
          args: ['echo placeholder: the fwrunner image is not in the registry yet']
          resources: {
            cpu: json('4')
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

// The gateway starts, follows and stops executions of this job, and nothing else.
resource runnerOperator 'Microsoft.Authorization/roleDefinitions@2022-04-01' = if (hasRunner && !empty(gateway.deployable)) {
  name: guid(resourceGroup().id, 'fwrunner-operator', stack.environmentName)
  properties: {
    roleName: '${stack.slug} ${stack.environmentName} fwrunner job operator'
    description: 'Start, read and stop executions of the job caj-${stack.slug}-${stack.environmentName}-fwrunner.'
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

@description('Settings for container deployables, by deployable and then by name: { "<deployable>": { "<NAME>": "<value>" } }. Each becomes an environment variable of that deployable\'s container app. Never a secret: a value here is readable in the deployment.')
output settings object = hasStore
  ? {
      '${deployable}': {
        '${containerUriSetting}': '${account!.properties.primaryEndpoints.blob}${containerName}'
        '${clientIdSetting}': identity.clientId
      }
    }
  : {}

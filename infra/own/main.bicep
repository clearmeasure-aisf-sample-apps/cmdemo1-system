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

@description('The generated secrets of the container deployables by vault name (<deployable>-<secret>), from ../main.bicep (infra/main.bicep passes its parameter of the same name; cmdemo1 edited that line, 2026-10-30). This file reads fworker-webhook-secret-azure-monitor only, for the address of the incident action group\'s webhook. Empty when ../main.bicep passes none (the preview of this file on its own): the webhook then stays off.')
@secure()
param generatedSecrets object = {}

@description('Whether the action group ag-<slug>-<env>-incident delivers to the gateway. FALSE until tdd runs the v2 engine (docs/deploy/incident-alert-rules.md of cmdemo1-fworker: before that the route answers 404 and Azure would retry every alert); the alert rules exist and fire into a group that does nothing. The cutover (W9.9) enables the webhook with this one default.')
param incidentWebhookEnabled bool = false

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

// Cloud worker runtime of the factory worker (cmdemo1-fworker docs/design/cloud-worker-runtimes.md, sections 2, 3
// and 6): Container Apps jobs, each execution of which runs one work item, as an identity of its own (no key anywhere):
// one for Claude Code (no model behind it, see runnerDeployment) and one with Codex CLI on an OpenAI deployment. In the
// environments below: tdd since 2026-10-15 (rollout step 2), uat and prod since 2026-10-16 (steps 5 and 6, Jeffrey:
// "Implement all phases").
var runnerEnvironments = ['tdd', 'uat', 'prod']
var hasRunner = contains(runnerEnvironments, stack.environmentName)
// No Foundry deployment of Claude: Azure Marketplace would not sell the subscription the Anthropic offer, and Jeffrey
// took Claude in Foundry out of scope (2026-10-16). The Claude job stays, as the image carries both agents, but no
// model backs it; the gateway runs Codex (FACTORY_RUNTIME_AGENT).
var runnerDeployment = 'claude-sonnet-5-5'
// The model of the Codex worker (Jeffrey, 2026-10-15).
var codexDeployment = 'gpt-6.1-sol'
// The connection to Foundry, off since 2026-10-16 (Jeffrey: "Abort any further testing or calls through AI foundry. Deactivate
// and disable the connection to AI foundry."): no public network access, no model deployment, no Foundry User role
// for the runner. The account itself stays, empty.
var foundryConnected = false
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
    publicNetworkAccess: foundryConnected ? 'Enabled' : 'Disabled'
  }
}

// The model of the Codex worker: an OpenAI model is sold by Microsoft itself, no Marketplace purchase.
resource sol 'Microsoft.CognitiveServices/accounts/deployments@2025-06-01' = if (hasRunner && foundryConnected) {
  parent: foundry
  name: codexDeployment
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

resource runnerModel 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasRunner && foundryConnected) {
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
          // Stopping one execution (POST .../executions/<name>/stop) is an action of its own.
          'Microsoft.App/jobs/stop/execution/action'
          'Microsoft.App/jobs/execution/read'
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

// The space scorecard's published site for other demo spaces (space-scorecard/ of this repository, steps 3 and 4 of the
// design "Space-level scorecard on cmis"): public blob containers of a storage account in prod, which the nightly
// runbook "Refresh space scorecard" of each such space (Octopus project <prefix>-scorecard-space of its space,
// environment prod) writes. cmdemo1's own pages left it for private GitHub Pages in step 5 (repository
// clearmeasure-aisf-sample-apps/cmdemo1-scorecard-site), with them its container "scorecard" and the federated
// credential of <slug>-scorecard-space.
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

// The factory worker gateway's own database (cmdemo1-fworker W2.2; Jeffrey, 2026-10-27), in tdd only: a small
// database (DTU Standard S0, see below) on tdd's SQL server, which the gateway reaches as its own identity id-<slug>-tdd-fworker (no
// password anywhere). Entra authentication needs an Entra administrator on the server: the operator identity cm-ai-ops,
// which gives the gateway's identity its contained user (infra/own/grant-fworker-database.ps1, run by the operator
// after a deployment that creates the database). The kit's SQL administrator login stays as it is; the ui app still
// connects with it. Nothing reads FACTORY_DB_CONNECTION until fworker W2.2 ships.
var factoryDatabaseEnvironments = ['tdd']
var hasFactoryDatabase = contains(factoryDatabaseEnvironments, stack.environmentName) && !empty(gateway.deployable)
// The server ../main.bicep makes (sqlServerName there): its region is system.sqlLocation, and a region of its own gives
// it a suffix of its own.
var sqlLocation = string(union({ sqlLocation: stack.location }, system.system).sqlLocation)
var sqlSuffix = sqlLocation == stack.location
  ? take(uniqueString(subscription().id, resourceGroup().id, stack.environmentName), 5)
  : take(uniqueString(subscription().id, resourceGroup().id, stack.environmentName, sqlLocation), 5)
var sqlServerName = 'sql-${stack.slug}-${stack.environmentName}-${sqlSuffix}'
var factoryDatabaseName = 'sqldb-${stack.slug}-${stack.environmentName}-fworker'
// The operator identity: service principal cm-ai-ops, as which the operator account aiops signs in. An application's
// SID is its client ID, not the object ID of its service principal.
var sqlEntraAdministrator = {
  login: 'cm-ai-ops'
  clientId: '2ad8c83f-2bb4-4a2e-abe4-3a7ff2ff089b'
}

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' existing = if (hasFactoryDatabase) {
  name: sqlServerName
}

resource sqlEntraAdmin 'Microsoft.Sql/servers/administrators@2023-08-01' = if (hasFactoryDatabase) {
  parent: sqlServer
  name: 'ActiveDirectory'
  properties: {
    administratorType: 'ActiveDirectory'
    login: sqlEntraAdministrator.login
    sid: sqlEntraAdministrator.clientId
    tenantId: tenant().tenantId
  }
}

// DTU Standard S0, 10 DTU and 2 GB, always on at a small fixed price (about $14.72 a month). It was serverless General
// Purpose (GP_S_Gen5, 0.5 to 1 vCore), but the gateway's Wolverine host keeps the database busy, so it never paused and
// billed about $309 a month (measured app_cpu_billed ~2,440 vCore-seconds an hour). Basic (5 DTU, about $4.90 a month) was
// tried next and timed out Wolverine's start (SqlException: Execution Timeout Expired in its start-up schema and lock
// work), so S0 is used. The data is ~47 MB. Backups in the region only.
resource factoryDatabase 'Microsoft.Sql/servers/databases@2023-08-01' = if (hasFactoryDatabase) {
  parent: sqlServer
  name: factoryDatabaseName
  location: sqlLocation
  tags: union(stack.tags, { purpose: 'fworker' })
  sku: {
    name: 'S0'
    tier: 'Standard'
    capacity: 10
  }
  properties: {
    maxSizeBytes: 2147483648
    requestedBackupStorageRedundancy: 'Local'
    zoneRedundant: false
  }
}

// No secret: the gateway signs in as its identity (the client ID says which of the app's identities).
var factoryDatabaseConnection = 'Server=tcp:${sqlServerName}${environment().suffixes.sqlServerHostname},1433;Database=${factoryDatabaseName};Authentication=Active Directory Managed Identity;User Id=${gateway.clientId};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'

// Incident alerts of the factory worker (cmdemo1-fworker W8.2b, issue 568; the specification is
// docs/deploy/incident-alert-rules.md of that repository), in tdd only: no rule for uat or prod.
//   - ag-<slug>-<env>-incident: the webhook to the gateway's /webhooks/azure-monitor, for the alerts of the app (deployable
//     ui). Its address carries the secret fworker-webhook-secret-azure-monitor (generated once in the vault by
//     apply-environment.ps1 and read by the gateway as FACTORY_WEBHOOK_SECRET_AZURE_MONITOR). The group is DISABLED while
//     incidentWebhookEnabled is false, and the rules below exist all the same.
//   - ag-<slug>-<env>-factory-owner: mail to the owners of the subscription (the role Owner; no address is written in this
//     public repository) for the alerts of the factory itself. It has no webhook on purpose: the factory's bus and database
//     cannot carry the report of their own failure.
// The address of the webhook shows in the action group to whoever can read it in the portal (Azure does not hide it): the
// secret protects a route that only opens, stores and joins incidents, and it is rotated in the vault and this stack together.
var incidentEnvironments = ['tdd']
// The Container Apps environment is the one the runner jobs use (managedEnvironment above): tdd's own, where the apps are.
var hasIncident = contains(incidentEnvironments, stack.environmentName) && hasRunner
var incidentTags = union(stack.tags, { purpose: 'incident-alerts' })
var incidentApp = 'ca-${stack.slug}-${stack.environmentName}-ui'
var factoryApp = 'ca-${stack.slug}-${stack.environmentName}-fworker'
var incidentSecret = string(generatedSecrets[?'fworker-webhook-secret-azure-monitor'] ?? '')
var incidentGroupName = 'ag-${stack.slug}-${stack.environmentName}-incident'
var ownerGroupName = 'ag-${stack.slug}-${stack.environmentName}-factory-owner'
// Locations of the standard web tests: South Central US, North Central US, West US, East US and Central US.
var webTestLocations = [
  { Id: 'us-tx-sn1-azr' }
  { Id: 'us-il-ch1-azr' }
  { Id: 'us-ca-sjc-azr' }
  { Id: 'us-va-ash-azr' }
  { Id: 'us-fl-mia-edge' }
]

// The things the alerts look at; all exist before this file runs on an existing environment, and are named as ../main.bicep
// names them (tdd owns its Container Apps environment and its apps carry no suffix).
resource incidentUi 'Microsoft.App/containerApps@2025-01-01' existing = if (hasIncident) {
  name: incidentApp
}

resource incidentFactory 'Microsoft.App/containerApps@2025-01-01' existing = if (hasIncident) {
  name: factoryApp
}

resource incidentInsights 'Microsoft.Insights/components@2020-02-02' existing = if (hasIncident) {
  name: 'appi-${stack.slug}-${stack.environmentName}'
}

resource incidentWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = if (hasIncident) {
  name: 'log-${stack.slug}-${stack.environmentName}'
}

resource incidentGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (hasIncident) {
  name: incidentGroupName
  location: 'global'
  tags: incidentTags
  properties: {
    groupShortName: take('${stack.environmentName}incident', 12)
    // Off without the switch, and off without the secret: an address with an empty secret would only collect 401s.
    enabled: incidentWebhookEnabled && !empty(incidentSecret)
    webhookReceivers: [
      {
        name: 'fworker-${stack.environmentName}'
        // One action group per deployable and environment: the address is the subject of the alert (the common schema does
        // not name the factory's deployable). useCommonAlertSchema is required: the gateway reads that schema only.
        serviceUri: 'https://${factoryApp}.${managedEnvironment!.properties.defaultDomain}/webhooks/azure-monitor?deployable=ui&environment=${stack.environmentName}&secret=${incidentSecret}'
        useCommonAlertSchema: true
        useAadAuth: false
      }
    ]
  }
}

resource ownerGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (hasIncident) {
  name: ownerGroupName
  location: 'global'
  tags: incidentTags
  properties: {
    groupShortName: 'factoryown'
    enabled: true
    // Mail to the people who own the subscription (role Owner). Never a webhook receiver here.
    armRoleReceivers: [
      {
        name: 'subscription-owners'
        roleId: '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
        useCommonAlertSchema: true
      }
    ]
  }
}

// Metric alerts (docs/deploy/incident-alert-rules.md sections 4 and 5). target: ui and fworker are the Container Apps; db is
// the factory's database. group: incident (the webhook) for the app's, owner for the factory's. Rule names as in the
// specification. The app's rules resolve themselves (autoMitigate) so a Resolved reaches the factory.
var metricRules = [
  { name: 'tdd-ui-replicas-zero', target: 'ui', namespace: 'Microsoft.App/containerApps', metric: 'Replicas', aggregation: 'Minimum', operator: 'LessThan', threshold: 1, window: 'PT5M', severity: 1, group: 'incident', dimensions: [] }
  { name: 'tdd-ui-5xx', target: 'ui', namespace: 'Microsoft.App/containerApps', metric: 'Requests', aggregation: 'Total', operator: 'GreaterThanOrEqual', threshold: 10, window: 'PT5M', severity: 2, group: 'incident', dimensions: [{ name: 'statusCodeCategory', operator: 'Include', values: ['5xx'] }] }
  { name: 'tdd-ui-restarts', target: 'ui', namespace: 'Microsoft.App/containerApps', metric: 'RestartCount', aggregation: 'Total', operator: 'GreaterThanOrEqual', threshold: 3, window: 'PT15M', severity: 2, group: 'incident', dimensions: [] }
  { name: 'tdd-fworker-replicas-zero', target: 'fworker', namespace: 'Microsoft.App/containerApps', metric: 'Replicas', aggregation: 'Minimum', operator: 'LessThan', threshold: 1, window: 'PT5M', severity: 1, group: 'owner', dimensions: [] }
  { name: 'tdd-fworker-5xx', target: 'fworker', namespace: 'Microsoft.App/containerApps', metric: 'Requests', aggregation: 'Total', operator: 'GreaterThanOrEqual', threshold: 10, window: 'PT5M', severity: 2, group: 'owner', dimensions: [{ name: 'statusCodeCategory', operator: 'Include', values: ['5xx'] }] }
  { name: 'tdd-fworker-db-connections', target: 'db', namespace: 'Microsoft.Sql/servers/databases', metric: 'connection_failed', aggregation: 'Total', operator: 'GreaterThanOrEqual', threshold: 5, window: 'PT5M', severity: 2, group: 'owner', dimensions: [] }
  // W8.2b (2026-10-30): DTU at 80% and size at 70% of the factory's database (S0: 10 DTU, 2 GB), earlier than the 85% of the specification.
  { name: 'tdd-fworker-db-dtu', target: 'db', namespace: 'Microsoft.Sql/servers/databases', metric: 'dtu_consumption_percent', aggregation: 'Average', operator: 'GreaterThan', threshold: 80, window: 'PT15M', severity: 3, group: 'owner', dimensions: [] }
  { name: 'tdd-fworker-db-size', target: 'db', namespace: 'Microsoft.Sql/servers/databases', metric: 'storage_percent', aggregation: 'Maximum', operator: 'GreaterThan', threshold: 70, window: 'PT15M', severity: 3, group: 'owner', dimensions: [] }
]
var activeMetricRules = filter(metricRules, r => hasIncident && (r.target != 'db' || hasFactoryDatabase))

resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for r in activeMetricRules: {
    name: r.name
    location: 'global'
    tags: incidentTags
    properties: {
      description: 'Incident alert rule ${r.name} (cmdemo1-fworker docs/deploy/incident-alert-rules.md).'
      severity: r.severity
      enabled: true
      scopes: [
        r.target == 'ui' ? incidentUi!.id : (r.target == 'fworker' ? incidentFactory!.id : factoryDatabase.id)
      ]
      evaluationFrequency: 'PT1M'
      windowSize: r.window
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            name: 'condition'
            criterionType: 'StaticThresholdCriterion'
            metricName: r.metric
            metricNamespace: r.namespace
            operator: r.operator
            threshold: r.threshold
            timeAggregation: r.aggregation
            dimensions: r.dimensions
          }
        ]
      }
      actions: [
        {
          actionGroupId: r.group == 'incident' ? incidentGroup.id : ownerGroup.id
        }
      ]
    }
  }
]

// Standard availability tests of Application Insights, every 5 minutes from 5 locations, and the metric alerts on them (a
// test that fails from two locations at once confirms an outage; this keeps the phantom incidents of 2026-09-13 away).
var webTests = [
  { key: 'ui-availability', rule: 'tdd-ui-availability', description: 'The detailed health check of the app in tdd (expects 200).', app: incidentApp, path: '/_healthcheck/detailed', window: 'PT5M', severity: 1, group: 'incident' }
  { key: 'fworker-not-ready', rule: 'tdd-fworker-not-ready', description: 'The /ready of the factory gateway in tdd (503 while it is not ready or was replaced).', app: factoryApp, path: '/ready', window: 'PT10M', severity: 1, group: 'owner' }
]

resource availabilityTests 'Microsoft.Insights/webtests@2022-06-15' = [
  for t in (hasIncident ? webTests : []): {
    name: 'wt-${stack.slug}-${stack.environmentName}-${t.key}'
    location: stack.location
    tags: union(incidentTags, { 'hidden-link:${incidentInsights!.id}': 'Resource' })
    kind: 'standard'
    properties: {
      SyntheticMonitorId: 'wt-${stack.slug}-${stack.environmentName}-${t.key}'
      Name: t.rule
      Description: t.description
      Enabled: true
      Frequency: 300
      Timeout: 30
      Kind: 'standard'
      RetryEnabled: true
      Locations: webTestLocations
      Request: {
        RequestUrl: 'https://${t.app}.${managedEnvironment!.properties.defaultDomain}${t.path}'
        HttpVerb: 'GET'
        ParseDependentRequests: false
      }
      ValidationRules: {
        ExpectedHttpStatusCode: 200
        IgnoreHttpStatusCode: false
        SSLCheck: true
        SSLCertRemainingLifetimeCheck: 7
      }
    }
  }
]

resource availabilityAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for (t, i) in (hasIncident ? webTests : []): {
    name: t.rule
    location: 'global'
    tags: union(incidentTags, {
      'hidden-link:${incidentInsights!.id}': 'Resource'
      'hidden-link:${availabilityTests[i].id}': 'Resource'
    })
    properties: {
      description: t.description
      severity: t.severity
      enabled: true
      scopes: [
        availabilityTests[i].id
        incidentInsights!.id
      ]
      evaluationFrequency: 'PT1M'
      windowSize: t.window
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.WebtestLocationAvailabilityCriteria'
        webTestId: availabilityTests[i].id
        componentId: incidentInsights!.id
        failedLocationCount: 2
      }
      actions: [
        {
          actionGroupId: t.group == 'incident' ? incidentGroup.id : ownerGroup.id
        }
      ]
    }
  }
]

// Log alerts (scheduled query rules). Exceptions of the app: 20 in 5 minutes. And the one the alert ingress itself feeds: the
// gateway writes {"alertIngress":"not-stored",...} whenever it could not put an alert into its inbox, which means incidents
// of the app arrive at a factory that cannot take them (the owner is told out of band).
resource exceptionsAlert 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (hasIncident) {
  name: 'tdd-ui-exceptions'
  location: stack.location
  tags: incidentTags
  properties: {
    displayName: 'tdd-ui-exceptions'
    description: 'Twenty or more exceptions of the app in five minutes.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [incidentInsights!.id]
    criteria: {
      allOf: [
        {
          query: 'exceptions'
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 20
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [incidentGroup.id]
    }
  }
}

resource alertsNotStoredAlert 'Microsoft.Insights/scheduledQueryRules@2022-06-15' = if (hasIncident) {
  name: 'tdd-fworker-alerts-not-stored'
  location: stack.location
  tags: incidentTags
  properties: {
    displayName: 'tdd-fworker-alerts-not-stored'
    description: 'The gateway could not store an alert of the app: incidents arrive at a factory that cannot take them.'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    scopes: [incidentWorkspace!.id]
    criteria: {
      allOf: [
        {
          query: 'ContainerAppConsoleLogs_CL | where ContainerAppName_s == \'${factoryApp}\' | where Log_s has \'"alertIngress":"not-stored"\''
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [ownerGroup.id]
    }
  }
}

// Reader access for the incident triage (a read-only look at Application Insights and the logs): the factory gateway's
// identity, on the environment's Application Insights and Log Analytics workspace only, and read-only roles only.
var monitoringReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var logAnalyticsReader = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')

resource triageInsights 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasIncident && !empty(gateway.deployable)) {
  scope: incidentInsights
  name: guid(incidentInsights.id, gateway.principalId, monitoringReader)
  properties: {
    principalId: gateway.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringReader
  }
}

resource triageWorkspace 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (hasIncident && !empty(gateway.deployable)) {
  scope: incidentWorkspace
  name: guid(incidentWorkspace.id, gateway.principalId, logAnalyticsReader)
  properties: {
    principalId: gateway.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: logAnalyticsReader
  }
}

@description('Settings for container deployables, by deployable and then by name: { "<deployable>": { "<NAME>": "<value>" } }. Each becomes an environment variable of that deployable\'s container app. Never a secret: a value here is readable in the deployment.')
output settings object = union(
  hasStore
    ? {
        '${deployable}': {
          '${containerUriSetting}': '${account!.properties.primaryEndpoints.blob}${containerName}'
          '${clientIdSetting}': identity.clientId
        }
      }
    : {},
  hasFactoryDatabase
    ? {
        fworker: {
          FACTORY_DB_CONNECTION: factoryDatabaseConnection
        }
      }
    : {}
)

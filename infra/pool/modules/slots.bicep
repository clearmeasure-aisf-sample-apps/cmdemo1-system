// Pull-request pool slots: one Container Apps environment and one container app per slot (pool-1 .. pool-N).
// Warm slots keep minReplicas 1 (shadow mode); cool slots scale to 0. Every slot is 1 vCPU / 2 GiB with
// maxReplicas on an HTTP concurrency rule. Image swaps and warm/cool changes are later work (pool manager);
// this module only defines the apps as code.
targetScope = 'resourceGroup'

param slug string
param location string
param tags object
param slots array

@description('How many of the first slots stay warm (minReplicas 1). Shadow mode: 2.')
@minValue(0)
param warmSlots int = 2

@description('vCPU of each slot app; Consumption pairs it with twice as many GiB (0.5, 1, 1.5 or 2).')
param cpu string = '1'

@description('Maximum replicas per slot; scale rule is HTTP concurrency.')
@minValue(1)
@maxValue(10)
param maxReplicas int = 3

@description('Concurrent HTTP requests that trigger a new replica.')
@minValue(1)
param httpConcurrentRequests int = 10

param registryServer string
param identityResourceId string

@description('Port of the ui deployable the slots run.')
param port int = 8080

@description('Health path of the ui deployable the slots run.')
param healthPath string = '/_healthcheck'

@description('Key Vault URI of each slot\'s SQL connection string secret, by slot name.')
param connectionStringSecretUris object

var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var placeholderPort = 80
var managedEnvironmentName = 'cae-${slug}-pool'
var memoryByCpu = {
  '0.5': '1Gi'
  '1': '2Gi'
  '1.5': '3Gi'
  '2': '4Gi'
}
var memory = memoryByCpu[?cpu] ?? '2Gi'
var resolvedCpu = contains(memoryByCpu, cpu) ? cpu : '1'

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: managedEnvironmentName
  location: location
  tags: tags
  properties: {
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource apps 'Microsoft.App/containerApps@2025-01-01' = [
  for (slot, i) in slots: {
    name: 'ca-${slug}-${slot}'
    location: location
    tags: union(tags, { slot: slot, warm: i < warmSlots ? 'true' : 'false' })
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${identityResourceId}': {}
      }
    }
    properties: {
      environmentId: managedEnvironment.id
      workloadProfileName: 'Consumption'
      configuration: {
        activeRevisionsMode: 'Single'
        ingress: {
          external: true
          targetPort: placeholderPort
          transport: 'auto'
          allowInsecure: false
        }
        registries: [
          {
            server: registryServer
            identity: identityResourceId
          }
        ]
        secrets: [
          {
            name: 'sql-connection-string'
            keyVaultUrl: connectionStringSecretUris[slot]
            identity: identityResourceId
          }
        ]
      }
      template: {
        containers: [
          {
            name: slot
            image: placeholderImage
            resources: {
              cpu: json(resolvedCpu)
              memory: memory
            }
            env: [
              {
                name: 'ConnectionStrings__SqlConnectionString'
                secretRef: 'sql-connection-string'
              }
              {
                name: 'OTEL_SERVICE_NAME'
                value: '${slug}-${slot}'
              }
              {
                name: 'POOL_SLOT'
                value: slot
              }
            ]
          }
        ]
        scale: {
          minReplicas: i < warmSlots ? 1 : 0
          maxReplicas: maxReplicas
          rules: [
            {
              name: 'http-concurrency'
              http: {
                metadata: {
                  concurrentRequests: string(httpConcurrentRequests)
                }
              }
            }
          ]
        }
      }
    }
  }
]

output managedEnvironmentName string = managedEnvironment.name
output slots array = [
  for (slot, i) in slots: {
    name: slot
    containerApp: apps[i].name
    url: 'https://${apps[i].properties.configuration.ingress.fqdn}'
    healthPath: healthPath
    port: port
    warm: i < warmSlots
    minReplicas: i < warmSlots ? 1 : 0
    maxReplicas: maxReplicas
  }
]

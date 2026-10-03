// Capability "baseline": one Container Apps environment (consumption, scale to zero) and one container app per
// deployable of system.json. A deployable without a version in environments/<env>/versions.json runs a placeholder
// image, so the environment exists before the first app build; the first deployment replaces it.
targetScope = 'resourceGroup'

param slug string
param environmentName string
param location string
param tags object
param deployables array
param versions object
param registryServer string
param identityResourceId string
param connectionStringSecretUri string
param applicationInsightsConnectionString string = ''

var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var placeholderPort = 80
var telemetryEnv = empty(applicationInsightsConnectionString)
  ? []
  : [
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: applicationInsightsConnectionString
      }
    ]

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${slug}-${environmentName}'
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

resource apps 'Microsoft.App/containerApps@2024-03-01' = [
  for d in deployables: {
    name: 'ca-${slug}-${environmentName}-${d.name}'
    location: location
    tags: union(tags, { deployable: d.name })
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
          targetPort: empty(versions[?d.name] ?? '') ? placeholderPort : d.port
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
            keyVaultUrl: connectionStringSecretUri
            identity: identityResourceId
          }
        ]
      }
      template: {
        containers: [
          {
            name: d.name
            image: empty(versions[?d.name] ?? '') ? placeholderImage : '${registryServer}/${slug}/${d.name}:${versions[d.name]}'
            resources: {
              cpu: json('0.5')
              memory: '1Gi'
            }
            env: concat(
              [
                {
                  name: 'ConnectionStrings__SqlConnectionString'
                  secretRef: 'sql-connection-string'
                }
              ],
              telemetryEnv
            )
          }
        ]
        scale: {
          minReplicas: 0
          maxReplicas: 1
        }
      }
    }
  }
]

output deployables array = [
  for (d, i) in deployables: {
    name: d.name
    containerApp: apps[i].name
    url: 'https://${apps[i].properties.configuration.ingress.fqdn}'
    healthPath: empty(versions[?d.name] ?? '') ? '/' : d.healthPath
    version: versions[?d.name] ?? ''
  }
]

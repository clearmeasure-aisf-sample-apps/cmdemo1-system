// Capability "baseline": one Container Apps environment (consumption, scale to zero) and one container app per
// deployable of system.json. A deployable without a version in environments/<env>/versions.json runs a placeholder
// image, so the environment exists before the first app build; the first deployment replaces it.
targetScope = 'resourceGroup'

param slug string
param environmentName string

@description('vCPU of each app container: 0.5, 1, 1.5 or 2; Consumption pairs it with twice as many GiB (the lookup fails for any other value).')
param appCpu string = '0.5'

@description('Name of the Container Apps environment; main.bicep gives it a region suffix when the environment has an appLocation of its own.')
param managedEnvironmentName string = 'cae-${slug}-${environmentName}'

@description('False when the apps run in the Container Apps environment of another environment (sharesAppEnvironmentWith), which creates it.')
param ownsManagedEnvironment bool = true

@description('Suffix of the app names when they do not run in their own default Container Apps environment, so a move creates them anew.')
param appNameSuffix string = ''
param location string
param tags object
param deployables array
param versions object
param registryServer string
param identityResourceId string
param connectionStringSecretUri string
@description('Application Insights connection string when the environment has capability "telemetry" (not a secret: it identifies where to send telemetry).')
param applicationInsightsConnectionString string = ''

var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var placeholderPort = 80
// Telemetry: the app's OpenTelemetry SDK exports to Application Insights with the Azure Monitor exporter whenever it
// gets APPLICATIONINSIGHTS_CONNECTION_STRING (traces, logs and metrics, Live Metrics too); without the capability it
// gets none and sends nothing. OTEL_SERVICE_NAME names each app (its role in Application Insights).
var telemetryEnv = empty(applicationInsightsConnectionString)
  ? []
  : [
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: applicationInsightsConnectionString
      }
    ]

resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = if (ownsManagedEnvironment) {
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

resource apps 'Microsoft.App/containerApps@2024-03-01' = [
  for d in deployables: {
    name: 'ca-${slug}-${environmentName}-${d.name}${appNameSuffix}'
    location: location
    tags: union(tags, { deployable: d.name })
    dependsOn: [
      managedEnvironment
    ]
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${identityResourceId}': {}
      }
    }
    properties: {
      environmentId: resourceId('Microsoft.App/managedEnvironments', managedEnvironmentName)
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
              cpu: json(appCpu)
              memory: { '0.5': '1Gi', '1': '2Gi', '1.5': '3Gi', '2': '4Gi' }[appCpu]
            }
            env: concat(
              [
                {
                  name: 'ConnectionStrings__SqlConnectionString'
                  secretRef: 'sql-connection-string'
                }
                {
                  name: 'OTEL_SERVICE_NAME'
                  value: '${slug}-${d.name}'
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
    hosting: 'containerapp'
    containerApp: apps[i].name
    url: 'https://${apps[i].properties.configuration.ingress.fqdn}'
    healthPath: empty(versions[?d.name] ?? '') ? '/' : d.healthPath
    version: versions[?d.name] ?? ''
  }
]

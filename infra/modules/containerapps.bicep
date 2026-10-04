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
@secure()
@description('Application Insights connection string when the environment has capability "telemetry"; the managed OpenTelemetry agent takes it as a secure value.')
param applicationInsightsConnectionString string = ''

var placeholderImage = 'mcr.microsoft.com/k8se/quickstart:latest'
var placeholderPort = 80
// Without telemetry the apps opt out of an OpenTelemetry agent they may share with another environment: an explicit
// OTEL_EXPORTER_OTLP_ENDPOINT overrides the one the agent injects, and an empty one keeps the app's exporter off.
var telemetryEnv = empty(applicationInsightsConnectionString)
  ? [
      {
        name: 'OTEL_EXPORTER_OTLP_ENDPOINT'
        value: ''
      }
    ]
  : []

// With capability "telemetry" the environment runs Container Apps' managed OpenTelemetry agent (a preview feature,
// hence the API version): it injects OTEL_EXPORTER_OTLP_ENDPOINT into every app, so the app only speaks OTLP, and
// forwards traces and logs to Application Insights. Application Insights takes no metrics from the agent; request
// rates and durations come from the traces.
resource managedEnvironment 'Microsoft.App/managedEnvironments@2024-10-02-preview' = if (ownsManagedEnvironment) {
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
    appInsightsConfiguration: empty(applicationInsightsConnectionString)
      ? null
      : {
          connectionString: applicationInsightsConnectionString
        }
    openTelemetryConfiguration: empty(applicationInsightsConnectionString)
      ? null
      : {
          tracesConfiguration: {
            destinations: [
              'appInsights'
            ]
          }
          logsConfiguration: {
            destinations: [
              'appInsights'
            ]
          }
        }
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

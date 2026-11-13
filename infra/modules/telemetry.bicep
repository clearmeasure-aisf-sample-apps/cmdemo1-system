// Capability "telemetry": Log Analytics plus workspace-based Application Insights. The apps of the environment (container
// apps) get APPLICATIONINSIGHTS_CONNECTION_STRING, and their OpenTelemetry SDK exports traces, logs
// and metrics to it with the Azure Monitor exporter; OTEL_SERVICE_NAME (<slug>-<deployable>) names each app's role.
// Turn it on by adding "telemetry" to the environment's capabilities in system.json.
// Nonprod (tdd/uat): ingestion sampling and 30-day App Insights retention cut cost; prod keeps the platform defaults.
// The workspace 1 GB/day cap and 30-day workspace retention stay for every tier.
targetScope = 'resourceGroup'

param slug string
param environmentName string
param location string
param tags object

@description('Environment tier from system.json (nonprod or prod). Nonprod enables App Insights sampling and 30-day retention.')
@allowed([
  'nonprod'
  'prod'
])
param tier string

// Cost reduction for nonprod only (#580): 25% ingestion sampling and 30-day component retention. Prod omits both so
// Azure keeps its existing defaults (100% sampling, 90-day retention) with no template-driven change.
var reduceCost = tier == 'nonprod'

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${slug}-${environmentName}'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    workspaceCapping: {
      dailyQuotaGb: 1
    }
  }
}

resource insights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${slug}-${environmentName}'
  location: location
  tags: tags
  kind: 'web'
  properties: union({
    Application_Type: 'web'
    WorkspaceResourceId: workspace.id
  }, reduceCost ? {
    RetentionInDays: 30
    SamplingPercentage: 25
  } : {})
}

output connectionString string = insights.properties.ConnectionString

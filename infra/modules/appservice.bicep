// Hosting "appservice": one Linux App Service plan on the Free tier (F1) per environment and one web app per App Service
// deployable of system.json. No registry: the app is a zip of the published .NET app on the built-in runtime, deployed
// by Octopus (scripts/deploy-appservice.ps1). It has no database of its own; its connection string is a Key Vault
// reference to a secret that only its own identity may read, for a login of its own in the system's database.
// Free tier limits: 60 CPU minutes a day, no Always On (the first request after idle starts the app), 165 MB outbound a
// day, no deployment slots.
targetScope = 'resourceGroup'

param slug string
param environmentName string
param location string
param tags object
param deployables array
param versions object
@description('User-assigned identity of each deployable, in the order of deployables.')
param identityResourceIds array
@description('Versionless Key Vault URI of each deployable\'s connection string, in the order of deployables.')
param connectionStringSecretUris array

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${slug}-${environmentName}'
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: 'F1'
    tier: 'Free'
  }
  properties: {
    reserved: true
  }
}

resource sites 'Microsoft.Web/sites@2024-04-01' = [
  for (d, i) in deployables: {
    name: 'app-${slug}-${environmentName}-${d.name}'
    location: location
    tags: union(tags, { deployable: d.name })
    kind: 'app,linux'
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${identityResourceIds[i]}': {}
      }
    }
    properties: {
      serverFarmId: plan.id
      httpsOnly: true
      keyVaultReferenceIdentity: identityResourceIds[i]
      siteConfig: {
        linuxFxVersion: 'DOTNETCORE|10.0'
        appCommandLine: 'dotnet ${d.startupAssembly}'
        alwaysOn: false
        ftpsState: 'Disabled'
        minTlsVersion: '1.2'
        http20Enabled: true
        appSettings: [
          {
            name: 'ConnectionStrings__SqlConnectionString'
            value: '@Microsoft.KeyVault(SecretUri=${connectionStringSecretUris[i]})'
          }
        ]
      }
    }
  }
]

output deployables array = [
  for (d, i) in deployables: {
    name: d.name
    hosting: 'appservice'
    webApp: sites[i].name
    url: 'https://${sites[i].properties.defaultHostName}'
    healthPath: empty(versions[?d.name] ?? '') ? '/' : d.healthPath
    version: versions[?d.name] ?? ''
  }
]

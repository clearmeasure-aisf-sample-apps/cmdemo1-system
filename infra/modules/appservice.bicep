// Hosting "appservice": a Linux App Service plan on the Free tier (F1) per tier and one web app per App Service
// deployable of system.json and environment. Azure allows one Free Linux plan per resource group, so the first
// environment of a tier creates the plan (ownsPlan) and the tier's other environments share it, quotas included. No registry: the app is a zip of the published .NET app on the built-in runtime, deployed
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
@description('Name of the tier\'s Free plan: asp-<slug>-<first environment of the tier>.')
param planName string
@description('True in the first environment of the tier, which creates the plan; the others use it.')
param ownsPlan bool
@description('User-assigned identity of each deployable, in the order of deployables.')
param identityResourceIds array
@description('Versionless Key Vault URI of each deployable\'s connection string, in the order of deployables.')
param connectionStringSecretUris array

resource plan 'Microsoft.Web/serverfarms@2024-04-01' = if (ownsPlan) {
  name: planName
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
    dependsOn: [
      plan
    ]
    identity: {
      type: 'UserAssigned'
      userAssignedIdentities: {
        '${identityResourceIds[i]}': {}
      }
    }
    properties: {
      serverFarmId: resourceId('Microsoft.Web/serverfarms', planName)
      httpsOnly: true
      keyVaultReferenceIdentity: identityResourceIds[i]
      siteConfig: {
        linuxFxVersion: 'DOTNETCORE|10.0'
        // No startup command until a version is pinned: an empty site with one crash-loops, and on a shared Free plan
        // the restarts exhaust the quota of every app on it. deploy-appservice.ps1 sets it right before the first zip.
        appCommandLine: empty(versions[?d.name] ?? '') ? '' : 'dotnet ${d.startupAssembly}'
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
    startupCommand: 'dotnet ${d.startupAssembly}'
    url: 'https://${sites[i].properties.defaultHostName}'
    healthPath: empty(versions[?d.name] ?? '') ? '/' : d.healthPath
    version: versions[?d.name] ?? ''
  }
]

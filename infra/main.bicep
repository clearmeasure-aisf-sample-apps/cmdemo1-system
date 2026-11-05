// Desired state of ONE environment of the system. Octopus applies it as the deployment stack stack-<slug>-<env>
// (scripts/apply-environment.ps1); pull requests preview it with what-if (scripts/preview-environment.ps1).
// Everything about the system comes from ../system.json; this file only reads it. An environment's capabilities
// (system.json, environments[].capabilities) switch modules on: "baseline" is always on, "telemetry" adds Log
// Analytics and Application Insights. A new capability is a new module plus one condition here.
targetScope = 'resourceGroup'

@description('Name of the environment in system.json, for example tdd.')
param environmentName string

@description('Deployed version of each deployable, from environments/<env>/versions.json on main. Empty means none yet: a placeholder runs.')
param versions object = {}

@description('SQL administrator password; apply-environment.ps1 reads it from the vault, or generates it on the first apply. Empty in a system without a database (no deployable has one), which creates no SQL server.')
@secure()
param sqlAdminPassword string = ''

@description('Principal ID of the deploy identity of this tier; it may read and write the vault secrets.')
param deployPrincipalId string

@description('Vault names (<deployable>-<secret>) of the operator-supplied secrets of container deployables that exist in the environment\'s vault; apply-environment.ps1 lists them. A container app references only the secrets named here.')
param presentSecrets array = []

@description('Value of each generated secret of a container deployable (deployables[].secrets[] with "generate": true), by vault name (<deployable>-<secret>); apply-environment.ps1 reads them from the vault, or generates them for a new secret.')
@secure()
param generatedSecrets object = {}

var system = loadJsonContent('../system.json')
var slug = system.system.slug
var location = system.system.location
// Azure SQL may need its own region: subscription offers restrict where new SQL servers can be created
// (RegionDoesNotAllowProvisioning). system.sqlLocation overrides location for the SQL server and database only.
// Optional keys come from defaults merged with union(): reading a key absent from system.json (.?key) is warning
// BCP053, and the build treats warnings as errors.
var sqlLocation = union({ sqlLocation: location }, system.system).sqlLocation
// Placement of the apps. A subscription allows only a few Container Apps environments per region
// (ManagedEnvironmentCount), so an environment may run its apps elsewhere:
//   - environments[].appLocation: its Container Apps environment and apps in that region;
//   - environments[].sharesAppEnvironmentWith: its apps in that environment's Container Apps environment (same tier,
//     listed earlier, which creates it), in that environment's region.
// Azure moves neither a Container Apps environment nor an app to another region or environment, so a placement that is
// not the default gets names of its own (a short suffix): a move is new resources next to the old ones, which the stack
// then removes. An explicit appLocation therefore always suffixes, also when it equals location.
//   - system.json azure.appEnvironment (the demo file's azure.appEnvironment "system"): the system owns one Container
//     Apps environment, which the seed created in a group of its own; every environment of both tiers places its apps
//     there, from its own tier group, and neither appLocation nor sharesAppEnvironmentWith applies
//     (scripts/test-system.ps1).
var rawEnvironment = first(filter(system.environments, e => e.name == environmentName))!
var environment = union({ appLocation: location, appCpu: '0.5' }, rawEnvironment)
var capabilities = union(['baseline'], environment.capabilities)
var systemAppEnvironment = union({ appEnvironment: {} }, system.azure).appEnvironment
var usesSystemAppEnvironment = !empty(systemAppEnvironment)
var sharedWith = string(union({ sharesAppEnvironmentWith: '' }, rawEnvironment).sharesAppEnvironmentWith)
var hostEnvironment = empty(sharedWith) ? rawEnvironment : first(filter(system.environments, e => e.name == sharedWith))!
var appLocation = usesSystemAppEnvironment ? string(systemAppEnvironment.location) : union({ appLocation: location }, hostEnvironment).appLocation
var placementSuffix = !usesSystemAppEnvironment && contains(hostEnvironment, 'appLocation') ? '-${take(uniqueString(appLocation), 4)}' : ''
var managedEnvironmentName = usesSystemAppEnvironment ? string(systemAppEnvironment.name) : 'cae-${slug}-${hostEnvironment.name}${placementSuffix}'
var ownsManagedEnvironment = !usesSystemAppEnvironment && hostEnvironment.name == environmentName
// In the system's environment the app names already carry the environment's name, so they need no suffix.
var appNameSuffix = usesSystemAppEnvironment || (ownsManagedEnvironment && empty(placementSuffix)) ? '' : '-${take(uniqueString(managedEnvironmentName), 4)}'
var app = first(filter(system.azure.identities.apps, a => a.environment == environmentName))!
var suffix = take(uniqueString(subscription().id, resourceGroup().id, environmentName), 5)
var tags = {
  system: slug
  environment: environmentName
  tier: environment.tier
  purpose: 'demo'
}

var vaultName = take('kv${slug}${environmentName}${suffix}', 24)
// SQL server names are global, and a create refused in one region keeps the name from another for a while; a SQL
// region of its own therefore gets a name of its own (unchanged when sqlLocation is location).
var sqlSuffix = sqlLocation == location ? suffix : take(uniqueString(subscription().id, resourceGroup().id, environmentName, sqlLocation), 5)
var sqlServerName = 'sql-${slug}-${environmentName}-${sqlSuffix}'
// system.sqlGeneration (1 when left out): raising it names a new database, so the stack deletes the old one with its
// data and creates the new one empty; the migrations then build its schema. Azure moves a database between serverless
// and Basic in place, but never from Basic (paid) back to the free offer: that takes a new database.
var sqlGeneration = int(union({ sqlGeneration: 1 }, system.system).sqlGeneration)
var databaseName = sqlGeneration > 1 ? 'sqldb-${slug}-${environmentName}-${sqlGeneration}' : 'sqldb-${slug}-${environmentName}'
var sqlAdminLogin = 'sqladmin'
var sqlServerFqdn = '${sqlServerName}${az.environment().suffixes.sqlServerHostname}'

// A deployable runs as a container app (modules/containerapps.bicep) unless deployables[].hosting says otherwise.
// This system keeps no App Service hosting (the kit's "appservice" and modules/appservice.bicep are left out here:
// scripts/test-system.ps1 refuses it), so the container deployable with a databasePackage owns the database and is the
// only app that reaches it.
// deployables[].hosting "staticwebapp": a site of static files on Azure Static Web Apps (modules/staticwebapp.bicep):
// the health dashboard, which has no server, no identity and no database login.
// "storagewebsite": the same site on a storage account's static website (modules/storagewebsite.bicep; opt-in).
// deployables[].environments (container deployables and static sites, scripts/test-system.ps1): the environments the deployable
// exists in; left out, it exists in every environment. An environment it does not name gets none of its resources.
// deployables[].retired (decision 0058): a retired deployable exists in no environment, so none of its resources, its
// identity, its secret references, its dashboard page or its Front Door origin is made; its Octopus project stays.
// A deployable with hosting "own" brings its runtime (principle 007): nothing below creates anything for it, and it
// is no entry of the output "deployables". Its own project deploys and verifies it.
var hostedDeployables = filter(
  map(system.deployables, d => union({ hosting: 'containerapp', environments: [environmentName] }, d)),
  d => contains(d.environments, environmentName) && !(d.?retired ?? false)
)
// A container deployable may declare more (all optional, modules/containerapps.bicep): a size of its own (cpu, and
// environmentCpu.<env> for one environment's size, the memory follows from it), one
// replica that never scales to zero (alwaysOn; only in the environments alwaysOnEnvironments names, when it names
// any), no database (database false: no SQL connection string), plain
// settings as environment variables (settings, and environmentSettings.<env> on top of them), its own public address
// as a setting (urlSetting), and secrets from the environment's vault (secrets: operator-supplied, or generated).
var containerDefaults = {
  cpu: string(environment.appCpu)
  environmentCpu: {}
  alwaysOn: false
  alwaysOnEnvironments: []
  database: true
  settings: {}
  environmentSettings: {}
  urlSetting: ''
  secrets: []
}
var containerDeployables = map(
  filter(hostedDeployables, d => d.hosting == 'containerapp'),
  d => union(containerDefaults, d)
)
// A secret's vault name is <deployable>-<secret>. A generated one is a secret of this stack (modules/keyvault.bicep);
// an operator-supplied one is written to the vault by the operator (the kit's set-demo-secret.ps1) and is no resource
// of the stack: the app references it once it exists (presentSecrets).
var containerSecrets = flatten(map(
  containerDeployables,
  d => map(d.secrets, s => union({ generate: false }, s, { deployable: d.name, vaultName: '${d.name}-${s.name}' }))
))
var generatedSecretNames = map(filter(containerSecrets, s => s.generate), s => s.vaultName)
// A container deployable that declares secrets reads them as an identity of its own, id-<slug>-<env>-<deployable>,
// which may read exactly its own secrets (a role on each secret, modules/keyvault.bicep). The environment's shared
// runtime identity still pulls its image, but its code cannot use that identity (modules/containerapps.bicep), and in
// an environment with such a deployable the shared identity reads only the SQL connection string, not the vault.
var secretDeployables = filter(containerDeployables, d => !empty(d.secrets))
var containerApps = map(containerDeployables, d => {
  name: d.name
  port: d.port
  healthPath: d.healthPath
  cpu: string(d.environmentCpu[?environmentName] ?? d.cpu)
  alwaysOn: d.alwaysOn && (empty(d.alwaysOnEnvironments) || contains(d.alwaysOnEnvironments, environmentName))
  database: d.database
  urlSetting: d.urlSetting
  secretIdentityId: empty(d.secrets)
    ? ''
    : resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', 'id-${slug}-${environmentName}-${d.name}')
  settings: map(
    items(union(d.settings, d.environmentSettings[?environmentName] ?? {})),
    s => { name: s.key, value: string(s.value) }
  )
  secrets: filter(
    containerSecrets,
    s => s.deployable == d.name && (s.generate || contains(presentSecrets, s.vaultName))
  )
})
var staticDeployables = filter(hostedDeployables, d => d.hosting == 'staticwebapp')
var storageDeployables = filter(hostedDeployables, d => d.hosting == 'storagewebsite')
// The environment has a database when an app in it uses one: a container deployable with database (the default).
// Without one (an app of the person's own, app.source "repository"), the environment has no SQL server and its vault
// holds no SQL secret.
var hasDatabase = !empty(filter(containerDeployables, d => d.database))
// The Free plan of Static Web Apps exists in a few regions only; the files are served from edge locations everywhere,
// so the region of the resource need not be the system's (system.staticLocation, optional).
var staticLocation = union({ staticLocation: 'centralus' }, system.system).staticLocation
// The dashboard runs in the browser and calls the health and version endpoints of every app itself, so with a static
// deployable the container apps answer requests from other origins (CORS): the page probes their health path while it shows them (decision 0038; a setting of their ingress, GET only). Every origin
// (*), not the dashboard's address: each environment's dashboard shows the nodes of every environment, so the origins
// to allow would be the sites of all environments, of both tiers; the endpoints it calls are public health and version
// endpoints that answer anyone anyway; and no credentials are sent or allowed. Without a static deployable nothing is
// set.
var corsAllowedOrigins = empty(staticDeployables) && empty(storageDeployables) ? [] : ['*']

// In the system's region, like the vault: a placement move of the apps leaves the identity and its roles as they are.
resource secretIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for d in secretDeployables: {
    name: 'id-${slug}-${environmentName}-${d.name}'
    location: location
    tags: union(tags, { deployable: d.name })
  }
]

module telemetry 'modules/telemetry.bicep' = if (contains(capabilities, 'telemetry')) {
  name: 'telemetry-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: appLocation
    tags: tags
  }
}

module sql 'modules/sql.bicep' = if (hasDatabase) {
  name: 'sql-${environmentName}'
  params: {
    serverName: sqlServerName
    databaseName: databaseName
    location: sqlLocation
    tags: tags
    administratorLogin: sqlAdminLogin
    administratorPassword: sqlAdminPassword
    // A database that is never left alone (apps on a Basic plan do not sleep, and their message bus polls it) uses
    // the month's free amount in about two days and is then paused until the next month: system.sqlFreeLimitExhaustion
    // "BillOverUsage" keeps it running at the serverless rate instead. Unset, it pauses.
    freeLimitExhaustionBehavior: string(union({ sqlFreeLimitExhaustion: 'AutoPause' }, system.system).sqlFreeLimitExhaustion) == 'BillOverUsage' ? 'BillOverUsage' : 'AutoPause'
    // system.sqlSku "Basic": a fixed-price database that is always on, for a system that is never left alone (its
    // Front Door probes the apps, the apps poll the database). Unset: serverless under the free offer.
    databaseSku: string(union({ sqlSku: 'Serverless' }, system.system).sqlSku) == 'Basic' ? 'Basic' : 'Serverless'
  }
}

module vault 'modules/keyvault.bicep' = {
  name: 'vault-${environmentName}'
  params: {
    name: vaultName
    location: location
    tags: tags
    readerPrincipalIds: [app.principalId]
    officerPrincipalIds: [deployPrincipalId]
    database: hasDatabase
    sqlAdminPassword: sqlAdminPassword
    sqlConnectionString: hasDatabase
      ? 'Server=tcp:${sqlServerFqdn},1433;Database=${databaseName};User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
      : ''
    generatedSecretNames: generatedSecretNames
    generatedSecrets: generatedSecrets
    narrowReaders: !empty(secretDeployables)
    secretIdentities: [
      for (d, i) in secretDeployables: {
        deployable: d.name
        principalId: secretIdentities[i].properties.principalId
      }
    ]
    // Only the secrets that exist: the generated ones, and the supplied ones the operator has written.
    secretGrants: map(
      filter(containerSecrets, s => s.generate || contains(presentSecrets, s.vaultName)),
      s => { deployable: s.deployable, vaultName: s.vaultName }
    )
  }
}

// Only with a static deployable: one Static Web App per deployable, in staticLocation.
module staticSites 'modules/staticwebapp.bicep' = if (!empty(staticDeployables)) {
  name: 'staticwebapp-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: staticLocation
    tags: tags
    deployables: staticDeployables
    versions: versions
  }
}

// Only with a storage website: one storage account per deployable, in the system's region.
module storageSites 'modules/storagewebsite.bicep' = if (!empty(storageDeployables)) {
  name: 'storagewebsite-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: location
    tags: tags
    deployables: storageDeployables
    versions: versions
    deployPrincipalId: deployPrincipalId
  }
}

// What the system adds to the environment itself (own/main.bicep, the system's file: the kit creates it empty once and
// no template sync changes it; principle 007). It gets the environment and the identity of each container deployable
// that has one of its own, and returns settings for container deployables, which reach their apps as environment
// variables. Its resources are resources of this stack.
module own 'own/main.bicep' = {
  name: 'own-${environmentName}'
  params: {
    // cmdemo1 (tdd, 2026-10-30): the generated secrets, for the one that is also part of an Azure resource, the secret in
    // the address of the incident action group's webhook (infra/own/main.bicep). The module returns none of them.
    generatedSecrets: generatedSecrets
    stack: {
      slug: slug
      environmentName: environmentName
      location: location
      tags: tags
      identities: [
        for (d, i) in secretDeployables: {
          deployable: d.name
          principalId: secretIdentities[i].properties.principalId
          clientId: secretIdentities[i].properties.clientId
          resourceId: secretIdentities[i].id
        }
      ]
    }
  }
}

// Only with a container deployable.
module apps 'modules/containerapps.bicep' = if (!empty(containerDeployables)) {
  name: 'apps-${environmentName}'
  dependsOn: [
    secretIdentities
  ]
  params: {
    slug: slug
    environmentName: environmentName
    managedEnvironmentName: managedEnvironmentName
    // The system's Container Apps environment is in a group of its own; any other is in this environment's tier group.
    managedEnvironmentResourceGroup: usesSystemAppEnvironment ? string(systemAppEnvironment.resourceGroup) : resourceGroup().name
    ownsManagedEnvironment: ownsManagedEnvironment
    // The system's environment may be an express one (system.json azure.appEnvironment.mode, from the seed).
    express: usesSystemAppEnvironment && union({ mode: 'standard' }, systemAppEnvironment).mode == 'express'
    appNameSuffix: appNameSuffix
    location: appLocation
    tags: tags
    deployables: containerApps
    ownSettings: own.outputs.settings
    vaultUri: vault.outputs.vaultUri
    versions: versions
    registryServer: union({ registry: { loginServer: '' } }, system.azure).registry.loginServer
    identityResourceId: app.resourceId
    connectionStringSecretUri: vault.outputs.connectionStringSecretUri
    applicationInsightsConnectionString: contains(capabilities, 'telemetry') ? telemetry!.outputs.connectionString : ''
    corsAllowedOrigins: corsAllowedOrigins
  }
}

output keyVaultName string = vaultName
// Without a database (hasDatabase false) the SQL outputs are empty: apply-environment.ps1 and the runbooks then skip
// every SQL step.
output hasDatabase bool = hasDatabase
output sqlServerName string = hasDatabase ? sqlServerName : ''
output sqlServerFqdn string = hasDatabase ? sqlServerFqdn : ''
output databaseName string = hasDatabase ? databaseName : ''
output sqlAdminLogin string = hasDatabase ? sqlAdminLogin : ''
output deployables array = concat(
  empty(containerDeployables) ? [] : apps!.outputs.deployables,
  empty(staticDeployables) ? [] : staticSites!.outputs.deployables,
  empty(storageDeployables) ? [] : storageSites!.outputs.deployables
)
output capabilities array = capabilities

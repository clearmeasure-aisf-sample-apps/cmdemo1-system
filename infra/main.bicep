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

@description('SQL administrator password; apply-environment.ps1 reads it from the vault, or generates it on the first apply.')
@secure()
param sqlAdminPassword string

@description('Principal ID of the deploy identity of this tier; it may read and write the vault secrets.')
param deployPrincipalId string

@description('Password of the database login of each App Service deployable, by name; apply-environment.ps1 reads them from the vault, or generates them for a new deployable.')
@secure()
param loginPasswords object = {}

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
var rawEnvironment = first(filter(system.environments, e => e.name == environmentName))!
var environment = union({ appLocation: location, appCpu: '0.5' }, rawEnvironment)
var capabilities = union(['baseline'], environment.capabilities)
var sharedWith = string(union({ sharesAppEnvironmentWith: '' }, rawEnvironment).sharesAppEnvironmentWith)
var hostEnvironment = empty(sharedWith) ? rawEnvironment : first(filter(system.environments, e => e.name == sharedWith))!
var appLocation = union({ appLocation: location }, hostEnvironment).appLocation
var placementSuffix = contains(hostEnvironment, 'appLocation') ? '-${take(uniqueString(appLocation), 4)}' : ''
var managedEnvironmentName = 'cae-${slug}-${hostEnvironment.name}${placementSuffix}'
var ownsManagedEnvironment = hostEnvironment.name == environmentName
var appNameSuffix = ownsManagedEnvironment && empty(placementSuffix) ? '' : '-${take(uniqueString(managedEnvironmentName), 4)}'
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
var databaseName = 'sqldb-${slug}-${environmentName}'
var sqlAdminLogin = 'sqladmin'
var sqlServerFqdn = '${sqlServerName}${az.environment().suffixes.sqlServerHostname}'

// A deployable runs as a container app (modules/containerapps.bicep) unless deployables[].hosting is "appservice": then
// a Linux web app on the Free plan (modules/appservice.bicep). An App Service deployable reaches the system's database
// with a login of its own (scripts/grant-database-access.ps1), whose connection string only its identity may read. One
// with a databasePackage owns the database (Octopus migrates it as the administrator, and its login may change the
// schema: the app creates its message queues at startup); the others share it, read and write.
// deployables[].hosting "staticwebapp": a site of static files on Azure Static Web Apps (modules/staticwebapp.bicep):
// the health dashboard, which has no server, no identity and no database login.
var hostedDeployables = map(system.deployables, d => union({ hosting: 'containerapp' }, d))
var containerDeployables = filter(hostedDeployables, d => d.hosting == 'containerapp')
var appServiceDeployables = filter(hostedDeployables, d => d.hosting == 'appservice')
var staticDeployables = filter(hostedDeployables, d => d.hosting == 'staticwebapp')
// The Free plan of Static Web Apps exists in a few regions only; the files are served from edge locations everywhere,
// so the region of the resource need not be the system's (system.staticLocation, optional).
var staticLocation = union({ staticLocation: 'centralus' }, system.system).staticLocation
// The dashboard runs in the browser and calls the health and version endpoints of every app itself, so with a static
// deployable the App Service apps answer requests from other origins (CORS). Every origin (*), not the dashboard's
// address: each environment's dashboard shows the nodes of every environment, so the origins to allow would be the
// sites of all environments, of both tiers; the endpoints it calls are public health and version endpoints that
// answer anyone anyway; and no credentials are sent or allowed. Without a static deployable nothing is set.
var corsAllowedOrigins = empty(staticDeployables) ? [] : ['*']

resource loginIdentities 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = [
  for d in appServiceDeployables: {
    name: 'id-${slug}-${environmentName}-${d.name}${placementSuffix}'
    location: appLocation
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

module sql 'modules/sql.bicep' = {
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
    sqlAdminPassword: sqlAdminPassword
    sqlConnectionString: 'Server=tcp:${sqlServerFqdn},1433;Database=${databaseName};User ID=${sqlAdminLogin};Password=${sqlAdminPassword};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
    logins: [
      for (d, i) in appServiceDeployables: {
        name: d.name
        // Only an identity that placement renamed gets a role assignment of its own (see modules/keyvault.bicep).
        renamedIdentity: empty(placementSuffix) ? '' : loginIdentities[i].name
        principalId: loginIdentities[i].properties.principalId
      }
    ]
    loginPasswords: loginPasswords
    loginConnectionStrings: toObject(
      appServiceDeployables,
      d => d.name,
      d =>
        'Server=tcp:${sqlServerFqdn},1433;Database=${databaseName};User ID=${d.name};Password=${loginPasswords[d.name]};Encrypt=True;TrustServerCertificate=False;Connection Timeout=60;'
    )
  }
}

// Azure allows one Free Linux App Service plan per resource group (FreeLinuxSkuNotAllowedInResourceGroup): the first
// environment of a tier owns the tier's plan, the others in the tier run their web apps on it. App Service uses the
// system's location (appLocation is a Container Apps quota matter).
var planOwner = first(filter(system.environments, e => e.tier == environment.tier))!.name
// system.planSku: { "<tier>": "B1" } gives a tier's plans, in the system's location and in its standby regions, a size
// without the Free plan's daily quotas (60 CPU minutes, 165 MB of outbound data for the whole plan: one run of browser
// acceptance tests exceeds it, as do a few visitors who each download the app, and Azure then stops every app on the
// plan until midnight UTC; a standby on a Free plan would be stopped by the very failover it exists for). While the system is
// dormant (azure.frontDoor.dormant, set-demo-frontdoor.ps1) every plan is Free again: nothing costs money between classes.
var planSkus = union({ nonprod: 'F1', prod: 'F1' }, union({ planSku: {} }, system.system).planSku)
var dormant = bool(union({ dormant: false }, union({ frontDoor: {} }, system.azure).frontDoor).dormant)
var planSku = (!dormant && string(planSkus[environment.tier]) == 'B1') ? 'B1' : 'F1'
// environments[].standbyLocation: the App Service apps a second time, in that region (primary and standby behind the
// environment's Front Door endpoint, capability "frontdoor"). The standby region's Free plan belongs to the first
// environment of the tier that has this standby region.
var standbyLocation = string(union({ standbyLocation: '' }, rawEnvironment).standbyLocation)
var standbyPlanOwner = empty(standbyLocation)
  ? environmentName
  : first(filter(system.environments, e => e.tier == environment.tier && union({ standbyLocation: '' }, e).standbyLocation == standbyLocation))!.name

module appService 'modules/appservice.bicep' = if (!empty(appServiceDeployables)) {
  name: 'appservice-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    location: location
    planName: 'asp-${slug}-${planOwner}'
    ownsPlan: planOwner == environmentName
    planSku: planSku
    tags: tags
    deployables: appServiceDeployables
    versions: versions
    identityResourceIds: [for (d, i) in appServiceDeployables: loginIdentities[i].id]
    connectionStringSecretUris: vault.outputs.loginConnectionStringUris
    applicationInsightsConnectionString: contains(capabilities, 'telemetry') ? telemetry!.outputs.connectionString : ''
    corsAllowedOrigins: corsAllowedOrigins
  }
}

module appServiceStandby 'modules/appservice.bicep' = if (!empty(appServiceDeployables) && !empty(standbyLocation)) {
  name: 'appservice-${environmentName}-standby'
  params: {
    slug: slug
    environmentName: environmentName
    location: standbyLocation
    planName: 'asp-${slug}-${standbyPlanOwner}-${standbyLocation}'
    ownsPlan: standbyPlanOwner == environmentName
    nameSuffix: '-${standbyLocation}'
    role: 'standby'
    planSku: planSku
    // The standby reports like the primary: its requests matter most after a failover.
    applicationInsightsConnectionString: contains(capabilities, 'telemetry') ? telemetry!.outputs.connectionString : ''
    tags: tags
    deployables: appServiceDeployables
    versions: versions
    identityResourceIds: [for (d, i) in appServiceDeployables: loginIdentities[i].id]
    connectionStringSecretUris: vault.outputs.loginConnectionStringUris
    corsAllowedOrigins: corsAllowedOrigins
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

// Only with a container deployable: a system whose apps all run on App Service has no Container Apps environment, and
// no registry either (system.json then has no azure.registry: the seed creates none).
module apps 'modules/containerapps.bicep' = if (!empty(containerDeployables)) {
  name: 'apps-${environmentName}'
  params: {
    slug: slug
    environmentName: environmentName
    managedEnvironmentName: managedEnvironmentName
    ownsManagedEnvironment: ownsManagedEnvironment
    appNameSuffix: appNameSuffix
    appCpu: string(environment.appCpu)
    location: appLocation
    tags: tags
    deployables: containerDeployables
    versions: versions
    registryServer: union({ registry: { loginServer: '' } }, system.azure).registry.loginServer
    identityResourceId: app.resourceId
    connectionStringSecretUri: vault.outputs.connectionStringSecretUri
    applicationInsightsConnectionString: contains(capabilities, 'telemetry') ? telemetry!.outputs.connectionString : ''
  }
}

output keyVaultName string = vaultName
output sqlServerName string = sqlServerName
output sqlServerFqdn string = sqlServerFqdn
output databaseName string = databaseName
output sqlAdminLogin string = sqlAdminLogin
output deployables array = concat(
  empty(containerDeployables) ? [] : apps!.outputs.deployables,
  empty(appServiceDeployables) ? [] : appService!.outputs.deployables,
  empty(staticDeployables) ? [] : staticSites!.outputs.deployables
)
// The same App Service deployables in the standby region (empty without a standbyLocation): the scripts deploy to and
// verify both, and the Front Door endpoint has both as origins.
output standby array = (empty(appServiceDeployables) || empty(standbyLocation)) ? [] : appServiceStandby!.outputs.deployables
output capabilities array = capabilities

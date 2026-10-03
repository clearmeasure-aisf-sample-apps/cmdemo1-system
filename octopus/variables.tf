# Project variables. The scripts read only these names; every value comes from system.json except GitHub.Token.

locals {
  # One entry per project and variable name; environment = null means unscoped.
  project_ids = merge(
    { system = octopusdeploy_project.system.id },
    { for name, project in octopusdeploy_project.deployable : name => project.id }
  )

  shared_variables = flatten([
    for project, id in local.project_ids : [
      { key = "${project}-slug", project = id, name = "System.Slug", value = local.slug, environment = null },
      { key = "${project}-repository", project = id, name = "System.Repository", value = local.repository, environment = null },
      { key = "${project}-registry", project = id, name = "Azure.RegistryServer", value = local.system.azure.registry.loginServer, environment = null },
      { key = "${project}-deployable", project = id, name = "Deployable.Name", value = project == "system" ? "" : project, environment = null },
      [for name, e in local.environments : {
        key         = "${project}-rg-${name}"
        project     = id
        name        = "Azure.ResourceGroup"
        value       = local.system.azure.resourceGroups[e.tier]
        environment = name
      }],
      [for name, e in local.environments : {
        key         = "${project}-principal-${name}"
        project     = id
        name        = "Azure.DeployPrincipalId"
        value       = local.system.azure.identities.deploy[e.tier].principalId
        environment = name
      }],
    ]
  ])

  deployable_variables = flatten([
    for name, d in local.deployables : [
      { key = "${name}-port", project = octopusdeploy_project.deployable[name].id, name = "Deployable.Port", value = tostring(d.port), environment = null },
      { key = "${name}-health", project = octopusdeploy_project.deployable[name].id, name = "Deployable.HealthPath", value = d.healthPath, environment = null },
      { key = "${name}-assembly", project = octopusdeploy_project.deployable[name].id, name = "Database.Assembly", value = d.databaseAssembly, environment = null },
    ]
  ])

  string_variables = { for v in concat(local.shared_variables, local.deployable_variables) : v.key => v }
}

resource "octopusdeploy_variable" "string" {
  for_each = local.string_variables

  owner_id = each.value.project
  name     = each.value.name
  type     = "String"
  value    = each.value.value

  dynamic "scope" {
    for_each = each.value.environment == null ? [] : [each.value.environment]
    content {
      environments = [octopusdeploy_environment.this[scope.value].id]
    }
  }
}

# Azure.Account: the tier's OIDC account, scoped to each environment of the tier.
resource "octopusdeploy_variable" "azure_account" {
  for_each = { for pair in setproduct(keys(local.project_ids), keys(local.environments)) : "${pair[0]}-${pair[1]}" => { project = pair[0], environment = pair[1] } }

  owner_id = local.project_ids[each.value.project]
  name     = "Azure.Account"
  type     = "AzureAccount"
  value    = octopusdeploy_azure_openid_connect.deploy[local.environments[each.value.environment].tier].id

  scope {
    environments = [octopusdeploy_environment.this[each.value.environment].id]
  }
}

resource "octopusdeploy_variable" "github_token" {
  for_each = local.project_ids

  owner_id        = each.value
  name            = "GitHub.Token"
  type            = "Sensitive"
  is_sensitive    = true
  sensitive_value = var.github_token
  description     = "Reads environments/<env>/versions.json from main and, in deployable projects, commits the pin. From repository secret OCTOPUS_GITHUB_TOKEN."
}

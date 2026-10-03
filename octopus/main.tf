# Provider, inputs and the objects every project shares. Known provider 1.20.0 limits (from the platform this template
# comes from): sort_order 0 counts as unset, and applies run with -parallelism=1.

variable "octopus_access_token" {
  description = "OIDC access token of the system's service account (OctopusDeploy/login sets OCTOPUS_ACCESS_TOKEN)."
  type        = string
  sensitive   = true
}

variable "github_token" {
  description = "GitHub token the pin step commits environments/<env>/versions.json with (repository secret OCTOPUS_GITHUB_TOKEN)."
  type        = string
  sensitive   = true
}

variable "worker_tools_image" {
  description = "Execution container of every step on Hosted Ubuntu: Azure CLI and PowerShell 7."
  type        = string
  default     = "octopusdeploy/worker-tools:6.6.5-ubuntu.24.04"
}

locals {
  system       = jsondecode(file("${path.module}/../system.json"))
  slug         = local.system.system.slug
  repository   = "${local.system.system.githubOrg}/${local.system.system.repository}"
  environments = { for i, e in local.system.environments : e.name => merge(e, { sort_order = i + 1 }) }
  tiers        = toset([for e in local.system.environments : e.tier])
  deployables  = { for d in local.system.deployables : d.name => d }
}

provider "octopusdeploy" {
  address      = local.system.octopus.url
  space_id     = local.system.octopus.spaceId
  access_token = var.octopus_access_token
}

resource "octopusdeploy_environment" "this" {
  for_each = local.environments

  name                         = each.key
  slug                         = each.key
  description                  = "${each.key} (${each.value.tier}) of ${local.system.system.name}; capabilities: ${join(", ", each.value.capabilities)}. Defined in system.json."
  sort_order                   = each.value.sort_order
  allow_dynamic_infrastructure = false
  use_guided_failure           = false
}

# The first environment deploys automatically; every later one is a manual promotion (an approval in the demo).
resource "octopusdeploy_lifecycle" "system" {
  name        = "${local.slug}-lifecycle"
  description = "Order of the environments in system.json: the first is automatic, the others are promoted by a person."

  dynamic "phase" {
    for_each = local.system.environments
    content {
      name                         = phase.value.name
      automatic_deployment_targets = phase.key == 0 ? [octopusdeploy_environment.this[phase.value.name].id] : []
      optional_deployment_targets  = phase.key == 0 ? [] : [octopusdeploy_environment.this[phase.value.name].id]
    }
  }
}

resource "octopusdeploy_project_group" "system" {
  name        = local.slug
  description = "${local.system.system.name}: the environments (${local.slug}-system) and one project per deployable."
}

# One account per tier, restricted to that tier's environments; subjects space/project/environment match the
# federated credentials of id-<slug>-deploy-<tier> that the seed created.
resource "octopusdeploy_azure_openid_connect" "deploy" {
  for_each = local.tiers

  name                              = "azure-${local.slug}-${each.key}"
  description                       = "id-${local.slug}-deploy-${each.key}: applies the environment stacks and updates the apps of ${each.key}."
  application_id                    = local.system.azure.identities.deploy[each.key].clientId
  tenant_id                         = local.system.azure.tenantId
  subscription_id                   = local.system.azure.subscriptionId
  audience                          = "api://AzureADTokenExchange"
  execution_subject_keys            = ["space", "project", "environment"]
  environments                      = [for name, e in local.environments : octopusdeploy_environment.this[name].id if e.tier == each.key]
  tenanted_deployment_participation = "Untenanted"
}

data "octopusdeploy_feeds" "built_in" {
  feed_type = "BuiltIn"
  take      = 1
}

resource "octopusdeploy_docker_container_registry" "docker_hub" {
  name                           = "docker-hub"
  feed_uri                       = "https://index.docker.io"
  api_version                    = "v2"
  download_attempts              = 3
  download_retry_backoff_seconds = 10
}

data "octopusdeploy_worker_pools" "hosted_ubuntu" {
  partial_name = "Hosted Ubuntu"
  take         = 10

  lifecycle {
    postcondition {
      condition     = length([for p in self.worker_pools : p if p.name == "Hosted Ubuntu"]) == 1
      error_message = "The dynamic worker pool 'Hosted Ubuntu' is missing from the space (Octopus Cloud provides it)."
    }
  }
}

locals {
  built_in_feed_id = data.octopusdeploy_feeds.built_in.feeds[0].id
  worker_pool_id   = one([for p in data.octopusdeploy_worker_pools.hosted_ubuntu.worker_pools : p.id if p.name == "Hosted Ubuntu"])
  container = {
    feed_id = octopusdeploy_docker_container_registry.docker_hub.id
    image   = var.worker_tools_image
  }
}

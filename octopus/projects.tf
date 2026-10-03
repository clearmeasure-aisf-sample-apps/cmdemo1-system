# The projects. <slug>-system applies infra/ to an environment (its releases are commits of this repository, packaged
# by job system-release); <slug>-<deployable> deploys one app release (created by the app repository's release
# workflow). The step scripts live in ../scripts and are read here, so a script change reaches Octopus on the next push.

resource "octopusdeploy_project" "system" {
  name                              = "${local.slug}-system"
  slug                              = "${local.slug}-system"
  description                       = "Environments of ${local.system.system.name}: each release is a commit of ${local.repository}; a deployment applies infra/ to one environment as a deployment stack."
  project_group_id                  = octopusdeploy_project_group.system.id
  lifecycle_id                      = octopusdeploy_lifecycle.system.id
  tenanted_deployment_participation = "Untenanted"
  default_guided_failure_mode       = "Off"
}

resource "octopusdeploy_project" "deployable" {
  for_each = local.deployables

  name                              = "${local.slug}-${each.key}"
  slug                              = "${local.slug}-${each.key}"
  description                       = "Deployable ${each.key} from ${local.system.system.githubOrg}/${each.value.repository}: pin, migrate, update, verify."
  project_group_id                  = octopusdeploy_project_group.system.id
  lifecycle_id                      = octopusdeploy_lifecycle.system.id
  tenanted_deployment_participation = "Untenanted"
  default_guided_failure_mode       = "Off"
}

# ---------------------------------------------------------------- <slug>-system

resource "octopusdeploy_process" "system" {
  project_id = octopusdeploy_project.system.id
}

resource "octopusdeploy_process_step" "system_apply" {
  process_id     = octopusdeploy_process.system.id
  name           = "Apply environment"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    system = {
      package_id           = "${local.slug}-system"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/apply-environment.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "system_verify" {
  process_id     = octopusdeploy_process.system.id
  name           = "Verify environment"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/verify-environment.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_steps_order" "system" {
  process_id = octopusdeploy_process.system.id
  steps = [
    octopusdeploy_process_step.system_apply.id,
    octopusdeploy_process_step.system_verify.id,
  ]
}

# ---------------------------------------------------------------- <slug>-<deployable>

resource "octopusdeploy_process" "deployable" {
  for_each = local.deployables

  project_id = octopusdeploy_project.deployable[each.key].id
}

# Desired state first: the new version is committed to environments/<env>/versions.json before anything changes.
resource "octopusdeploy_process_step" "pin" {
  for_each = local.deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Pin version"
  type           = "Octopus.Script"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/pin-version.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "migrate" {
  for_each = local.deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Migrate database"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    database = {
      package_id           = each.value.databasePackage
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/migrate-database.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "update" {
  for_each = local.deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Update deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/update-deployable.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_step" "verify" {
  for_each = local.deployables

  process_id     = octopusdeploy_process.deployable[each.key].id
  name           = "Verify deployable"
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/verify-environment.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_steps_order" "deployable" {
  for_each = local.deployables

  process_id = octopusdeploy_process.deployable[each.key].id
  steps = [
    octopusdeploy_process_step.pin[each.key].id,
    octopusdeploy_process_step.migrate[each.key].id,
    octopusdeploy_process_step.update[each.key].id,
    octopusdeploy_process_step.verify[each.key].id,
  ]
}

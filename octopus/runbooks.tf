# Operations runbooks of <slug>-system (environment-level work, run on a schedule):
#   Restore test          weekly, first environment: point-in-time restore into a temporary database (CAP-060)
#   Rotate SQL password   monthly, every environment: new administrator password through Key Vault (CAP-056)
# A schedule runs the runbook's published snapshot; the system workflow publishes one after every apply.

locals {
  first_environment = local.system.environments[0].name
  runbooks = {
    restore_test = {
      name         = "Restore test"
      description  = "Restores the database to 15 minutes ago into a temporary database, checks it, and deletes it (scripts/test-restore.ps1)."
      script       = "test-restore.ps1"
      environments = [local.first_environment]
      cron         = "0 0 7 * * Sun"
      schedule     = "Weekly restore test"
    }
    rotate_sql_password = {
      name         = "Rotate SQL password"
      description  = "New SQL administrator password through Key Vault, app restart and health check (scripts/rotate-sql-password.ps1)."
      script       = "rotate-sql-password.ps1"
      environments = [for name, e in local.environments : name]
      cron         = "0 0 8 1 * *"
      schedule     = "Monthly SQL password rotation"
    }
  }
}

resource "octopusdeploy_runbook" "this" {
  for_each = local.runbooks

  project_id                  = octopusdeploy_project.system.id
  name                        = each.value.name
  description                 = each.value.description
  environment_scope           = "Specified"
  environments                = [for name in each.value.environments : octopusdeploy_environment.this[name].id]
  default_guided_failure_mode = "Off"
  force_package_download      = false
}

resource "octopusdeploy_process" "runbook" {
  for_each = local.runbooks

  project_id = octopusdeploy_project.system.id
  runbook_id = octopusdeploy_runbook.this[each.key].id
}

resource "octopusdeploy_process_step" "runbook" {
  for_each = local.runbooks

  process_id     = octopusdeploy_process.runbook[each.key].id
  name           = each.value.name
  type           = "Octopus.AzurePowerShell"
  worker_pool_id = local.worker_pool_id
  container      = local.container

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/${each.value.script}")
    "OctopusUseBundledTooling"           = "False"
  }
}

resource "octopusdeploy_process_steps_order" "runbook" {
  for_each = local.runbooks

  process_id = octopusdeploy_process.runbook[each.key].id
  steps      = [octopusdeploy_process_step.runbook[each.key].id]
}

resource "octopusdeploy_project_scheduled_trigger" "runbook" {
  for_each = local.runbooks

  project_id  = octopusdeploy_project.system.id
  space_id    = local.system.octopus.spaceId
  name        = each.value.schedule
  description = "${each.value.name}: ${each.value.description}"
  timezone    = "UTC"

  cron_expression_schedule {
    cron_expression = each.value.cron
  }

  run_runbook_action {
    runbook_id             = octopusdeploy_runbook.this[each.key].id
    target_environment_ids = [for name in each.value.environments : octopusdeploy_environment.this[name].id]
  }
}

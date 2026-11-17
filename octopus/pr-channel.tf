# Pull requests ephemeral channel: a native ephemeral channel with fixed slot names
# (pool-1 to pool-8), scoped to the ui project. Values scope to the parent; per-slot
# names come from #{Octopus.Environment.Name}. Slots skip Sign-off, the pin and the
# records. Releases look like 2.4.<run>-pr.<n> to pool-N in this channel.
#
# The parent environment is a placeholder that owns the slot environments; the slots
# themselves are ephemeral environments created from releases in this channel.
# The channel template is pool-#{Octopus.Release.CustomFields[Slot]}, which resolves
# to pool-1 … pool-8 when the release carries a Slot custom field in that range.
#
# The combined slot step runs migrate, swap the image, and verify in sequence.
# It excludes Sign-off, the pin, and the records that tdd/uat/prod have.

locals {
  # The Pull requests channel is scoped to the ui project only.
  pr_channel_project_id = octopusdeploy_project.deployable["ui"].id

  # The parent environment id for ephemeral environments in this channel.
  pr_parent_env_id = octopusdeploy_parent_environment.pr_parent.id

  # The 8 slot environments: pool-1 through pool-8. They are child environments of
  # the parent and are scoped to the parent environment.
  pr_slot_environments = { for i in range(1, 9) : "pool-${i}" => {
    name        = "pool-${i}"
    slug        = "pool-${i}"
    description = "PR slot ${i}: ephemeral environment child of pool-parent for the Pull requests channel."
    sort_order  = i
  } }

  # The ui project's deployable (container app) that the slot step updates.
  ui_deployable = local.deployables["ui"]

  # The combined slot step packages: the ui package from the built-in feed.
  pr_slot_package = {
    ui = {
      package_id           = "${local.slug}-ui"
      feed_id              = local.built_in_feed_id
      acquisition_location = "Server"
      properties = {
        Extract       = "True"
        Purpose       = ""
        SelectionMode = "immediate"
      }
    }
  }
}

# ---------------------------------------------------------------- pool-parent (parent environment)

resource "octopusdeploy_parent_environment" "pr_parent" {
  name        = "pool-parent"
  space_id    = local.system.octopus.spaceId
  description = "Parent environment for PR slot ephemeral environments (pool-1 … pool-8). Managed by octopus/ of ${local.repository}."
  slug        = "pool-parent"
  sort_order  = 10
}

# ---------------------------------------------------------------- pool-1 … pool-8 (slot environments)

resource "octopusdeploy_environment" "pr_slot" {
  for_each = local.pr_slot_environments

  name                         = each.value.name
  slug                         = each.value.slug
  description                  = each.value.description
  sort_order                   = each.value.sort_order
  allow_dynamic_infrastructure = false
  use_guided_failure           = false
}

# ---------------------------------------------------------------- Pull requests channel (ephemeral)

resource "octopusdeploy_channel" "pr_channel" {
  name                                = "Pull requests"
  project_id                          = local.pr_channel_project_id
  space_id                            = local.system.octopus.spaceId
  description                         = "Ephemeral channel for pull request deployments. Releases carry a Slot custom field (1–8) that resolves to pool-1 … pool-8."
  is_default                          = false
  type                                = "EphemeralEnvironment"
  ephemeral_environment_name_template = "pool-#{Octopus.Release.CustomFields[Slot]}"
  parent_environment_id               = local.pr_parent_env_id

  custom_field_definitions = [
    {
      field_name  = "Slot"
      description = "Slot number (1–8) for the ephemeral environment name (e.g., pool-3)."
    }
  ]
}

# ---------------------------------------------------------------- Combined slot step: migrate, swap, verify

# The slot step runs in the PR slot environments (pool-1 … pool-8). It skips Sign-off,
# the pin, and the records that tdd/uat/prod have.

resource "octopusdeploy_process" "pr_slot" {
  project_id = octopusdeploy_project.deployable["ui"].id
}

# Migrate database step (only for deployables with a database; ui has one).
resource "octopusdeploy_process_step" "pr_slot_migrate" {
  process_id     = octopusdeploy_process.pr_slot.id
  name           = "Migrate database"
  type           = "Octopus.AzurePowerShell"
  environments   = [for name in keys(local.pr_slot_environments) : octopusdeploy_environment.pr_slot[name].id]
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = {
    database = {
      package_id           = local.ui_deployable.databasePackage
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

# Update deployable step (swap the image).
resource "octopusdeploy_process_step" "pr_slot_update" {
  process_id     = octopusdeploy_process.pr_slot.id
  name           = "Update deployable"
  type           = "Octopus.AzurePowerShell"
  environments   = [for name in keys(local.pr_slot_environments) : octopusdeploy_environment.pr_slot[name].id]
  worker_pool_id = local.worker_pool_id
  container      = local.container

  packages = local.pr_slot_package

  execution_properties = {
    "Octopus.Action.Azure.AccountId"     = "#{Azure.Account}"
    "Octopus.Action.RunOnServer"         = "true"
    "Octopus.Action.Script.ScriptSource" = "Inline"
    "Octopus.Action.Script.Syntax"       = "PowerShell"
    "Octopus.Action.Script.ScriptBody"   = file("${path.module}/../scripts/update-deployable.ps1")
    "OctopusUseBundledTooling"           = "False"
  }
}

# Verify deployable step.
resource "octopusdeploy_process_step" "pr_slot_verify" {
  process_id     = octopusdeploy_process.pr_slot.id
  name           = "Verify deployable"
  type           = "Octopus.AzurePowerShell"
  environments   = [for name in keys(local.pr_slot_environments) : octopusdeploy_environment.pr_slot[name].id]
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

# Step ordering: migrate → update → verify (no Sign-off, no pin, no records).
resource "octopusdeploy_process_steps_order" "pr_slot" {
  process_id = octopusdeploy_process.pr_slot.id
  steps = [
    octopusdeploy_process_step.pr_slot_migrate.id,
    octopusdeploy_process_step.pr_slot_update.id,
    octopusdeploy_process_step.pr_slot_verify.id,
  ]
}

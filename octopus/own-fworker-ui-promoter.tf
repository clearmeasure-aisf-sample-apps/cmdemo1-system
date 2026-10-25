# cmdemo1's own file (fleet.ownedTemplates of its registry file in the kit): the team "fworker ui promoter", through
# which the factory-worker gateway's Octopus service account promotes releases of cmdemo1-ui to uat and prod once its
# own gate passes (Jeffrey, 2026-10-23; cmdemo1-system #300). Answering the Sign-off of those deployments comes from
# the kit's team "cmdemo1 pipeline sign-off" (system.pipelineSignOffMembers, decision 0057); this team grants what
# that one does not: seeing ui's releases, deployments and tasks, creating deployments in uat and prod, and viewing and
# submitting their manual interventions (InterruptionView, InterruptionSubmit). Decision 0057 leaves extra scoped teams
# and roles to the system's own octopus/ files until a second system needs the same.
#
# The team was made by hand on 2026-10-23 and is imported (the import blocks below), so it keeps its ids: Teams-404,
# ScopedUserRoles-962 and -963. Terraform owns its membership and scopes from then on: a change in the Octopus UI is
# drift that the next apply undoes. The import blocks do nothing once the objects are in the state; should one of the
# objects be deleted in Octopus, its import block must go too, or every plan fails on the missing id.
#
# The two roles are instance-wide custom roles (UserRoles-149 "fworker ui release viewer", UserRoles-150 "fworker ui
# promoter"). Changing a role needs UserRoleEdit, a system permission the system's service account does not hold (it
# has UserRoleView: reference.md, "Who signs off"), so the roles are read here, not managed: the plan fails, and says
# so, when a role no longer grants exactly the permissions below. An Octopus administrator changes a role, and this
# file with it.

locals {
  fworker_ui_promoter_login = "cmdemo1-fworker-gateway-agent"

  # Per role: its id, its name and the space permissions it must grant, and the environments of cmdemo1-ui it is
  # scoped to.
  fworker_ui_promoter_roles = {
    viewer = {
      id           = "UserRoles-149"
      name         = "fworker ui release viewer"
      permissions  = ["DeploymentView", "EnvironmentView", "ProjectView", "ReleaseView", "TaskView"]
      environments = ["tdd", "uat", "prod"]
    }
    promoter = {
      id           = "UserRoles-150"
      name         = "fworker ui promoter"
      permissions  = ["DeploymentCreate", "DeploymentView", "EnvironmentView", "InterruptionSubmit", "InterruptionView", "ProjectView", "ReleaseView", "TaskView"]
      environments = ["uat", "prod"]
    }
  }
}

data "octopusdeploy_users" "fworker_ui_promoter" {
  filter = local.fworker_ui_promoter_login
  take   = 100

  lifecycle {
    postcondition {
      condition     = length([for u in self.users : u.id if lower(u.username) == local.fworker_ui_promoter_login]) == 1
      error_message = "No single Octopus user has the username '${local.fworker_ui_promoter_login}', the factory-worker gateway's service account."
    }
  }
}

data "octopusdeploy_user_roles" "fworker_ui_promoter" {
  ids = [for r in values(local.fworker_ui_promoter_roles) : r.id]

  lifecycle {
    postcondition {
      condition = alltrue([
        for r in values(local.fworker_ui_promoter_roles) : length([
          for role in self.user_roles : role.id
          if role.id == r.id && role.name == r.name && toset(role.granted_space_permissions) == toset(r.permissions) && length(coalesce(role.granted_system_permissions, [])) == 0
        ]) == 1
      ])
      error_message = "UserRoles-149 or UserRoles-150 no longer has the name and exactly the space permissions octopus/own-fworker-ui-promoter.tf names (and no system permission). An Octopus administrator changes the role and this file together."
    }
  }
}

import {
  to = octopusdeploy_team.fworker_ui_promoter
  id = "Teams-404"
}

resource "octopusdeploy_team" "fworker_ui_promoter" {
  name        = "fworker ui promoter"
  description = "The fworker gateway (Agent account) promoting cmdemo1-ui when its gate passes. Jeffrey 2026-10-23."
  space_id    = local.system.octopus.spaceId
  users       = [one([for u in data.octopusdeploy_users.fworker_ui_promoter.users : u.id if lower(u.username) == local.fworker_ui_promoter_login])]
}

import {
  to = octopusdeploy_scoped_user_role.fworker_ui_promoter["viewer"]
  id = "ScopedUserRoles-962"
}

import {
  to = octopusdeploy_scoped_user_role.fworker_ui_promoter["promoter"]
  id = "ScopedUserRoles-963"
}

resource "octopusdeploy_scoped_user_role" "fworker_ui_promoter" {
  for_each = local.fworker_ui_promoter_roles

  team_id         = octopusdeploy_team.fworker_ui_promoter.id
  space_id        = local.system.octopus.spaceId
  user_role_id    = one([for role in data.octopusdeploy_user_roles.fworker_ui_promoter.user_roles : role.id if role.id == each.value.id])
  project_ids     = [octopusdeploy_project.deployable["ui"].id]
  environment_ids = [for e in each.value.environments : octopusdeploy_environment.this[e].id]
}

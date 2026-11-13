# cmdemo1-ui feature toggles

Building management and vendor management are Octopus feature toggles on project **cmdemo1-ui** (`Projects-981`) in space **cmdemo1-demo** (`Spaces-355`). The API is `/api/Spaces-355/projects/Projects-981/featuretoggles`. The project UI may label that screen **Feature Flags**. This runbook calls them toggles.

Targeting uses the **rules** model ([feature flags](https://octopus.com/docs/feature-flags), [rules](https://octopus.com/docs/feature-flags/rules), [upgrading to rules](https://octopus.com/docs/feature-flags/upgrading-to-rules)). Each environment has an on/off switch and optional phases of rules. An environment that is on with no rules is on for everyone. An environment that is off is off for everyone, whatever its rules say. An environment with no row uses the flag default.

| Toggle | Slug the script requests | tdd | uat | prod | Flag default |
|---|---|---|---|---|---|
| `BuildingManagement` | `BuildingManagement` | on (no rules) | off | off | off |
| `VendorManagement` | `VendorManagement` | on (no rules) | off | off | off |

The app evaluates the **slug**. The script asks Octopus to use the name as the slug. If Octopus assigns a different slug, the script prints it: that printed slug is the evaluation key, and [cmdemo1-workorders#1466](https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/1466) has to use it.

`tdd` stays on so Buildings and Vendors acceptance keeps passing once the app reads the toggles. `uat` and `prod` stay off until someone flips them for a demo. A missing client identifier also fails closed in the app.

On means the surface is available. Off hides it and rejects the call.

| Toggle | On | Off, and still available |
|---|---|---|
| `BuildingManagement` | Nav **Buildings & Rooms**, `/admin/buildings`, building-room summary reads | Work order building text, the Open by Building report |
| `VendorManagement` | Vendors on Teams & Vendors, vendor commands and queries, MCP vendor tools | Waiting on a vendor, the teams portion of that page |

After a project is upgraded to rules, applications on an OpenFeature provider **below the minimum** keep the flag values they had at upgrade time and do not see later flips ([providers](https://octopus.com/docs/feature-flags/providers)). cmdemo1-workorders already references `Octopus.OpenFeature` **4.0.0**, the minimum .NET version for rules. Upgrade every consumer before upgrading the project; the upgrade cannot be undone.

## What does not apply them

`octopus/` is Terraform provider `OctopusDeploy/octopusdeploy` **1.20.0**, which has no feature-toggle resource. Job `system` (`octopus-apply`) does not create these toggles and does not put a flipped environment back. Do not copy the on/off values into `system.json` `settings`: those are container environment variables, not feature flags, and they would ship only on a system deployment.

The client identifier is the Octopus variable `Octopus.FeatureFlags.ClientIdentifier` (current name). `Octopus.FeatureToggles.ClientIdentifier` is a deprecated alias that still works. It is a JWT for the flag service. Do not write it into git, `system.json`, an issue, a PR, or a workflow log. Do not print it. Repository secret `OCTOPUS_FEATURES_CLIENT_IDENTIFIER` (name only; never the value) feeds Terraform as `TF_VAR_feature_toggles_client_identifier`; `octopus/` creates both Octopus variable names on project `cmdemo1-ui` when that secret has text. `scripts/update-deployable.ps1` prefers `Octopus.FeatureFlags.ClientIdentifier`, falls back to `Octopus.FeatureToggles.ClientIdentifier`, and writes the value onto the UI container app as `Octopus__FeatureFlags__ClientIdentifier` when either has text and the deployable is `ui`. Empty leaves the update unchanged. Octopus inlines that script when the system configuration is applied. A `ui` release created after that apply is the one that injects it. A project without the variable is unchanged.

Acceptance is a live flip in `tdd`: after the identifier reaches the tdd ui container, flipping a `cmdemo1-ui` flag in Octopus changes tdd `GET /api/features/flags`. That flip also proves Container Apps can reach `https://features.octopus.com`.

## Create

No API key is stored in this repository. The script reads `OCTOPUS_API_KEY`, or `OCTOPUS_ACCESS_TOKEN` from `OctopusDeploy/login`. Put the key in the environment. Do not pass it as an argument (shell history and process listings keep arguments).

`scripts/ensure-ui-feature-toggles.ps1` speaks the rules payload only ([API](https://octopus.com/docs/api/feature-flags)): each environment is `DeploymentEnvironmentId`, `IsEnabled`, and `Phases` (empty for the defaults above). It does not send `RolloutPercentage` or other legacy targeting fields. It does not run the project upgrade. If a stored toggle still has legacy targeting, a write is refused until the project is upgraded in Octopus.

From a checkout of this repository, with no credential, this prints the create and does not call Octopus:

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -WhatIf
```

With a credential that can edit feature toggles on `cmdemo1-ui`:

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1
```

Ensure creates a missing toggle at the defaults above (rules shape). Running it again does not turn `uat` or `prod` back off after a flip. An environment that is missing from an existing toggle is added at the default. `-ResetDefaults` is the way back to the table (phases already stored on an environment stay; legacy rollout fields are not rewritten):

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -ResetDefaults
```

After this workflow is on `main`, Actions → **ui-feature-toggles** → Run workflow runs that same Ensure as the system's Octopus service account (`OctopusDeploy/login`, GitHub environment `octopus`). It does not run on push, so a merge does not reset a demo flip. If the run stops with 403, that account can read the project and cannot edit feature toggles: run the script as a user who can. If Octopus answers 404, the instance is not serving `/featuretoggles` on this project. Create the two toggles in the UI instead (next section) with the same names and the same on/off values, leave the toggle default off, and leave rules empty on `tdd`.

Read what is stored:

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Show
```

## Flip

1. Open project `cmdemo1-ui` in space `cmdemo1-demo`: [cmdemo1-ui](https://clearmeasure.octopus.app/app#/Spaces-355/projects/Projects-981).
2. Open **Feature Flags**, then `BuildingManagement` or `VendorManagement`.
3. In the environment's rules editor, turn the environment switch on or off (`tdd`, `uat`, or `prod`). Leave rules empty unless you are narrowing who gets the flag. Save. Octopus publishes the manifest on save. This is not a release and not a new container image.
4. Or, with a credential in the environment. These lines work as written in bash and in pwsh. `-Enabled:false` and `-Enabled:true` contain no `$`, so both shells pass that text through:

```text
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Set -Name BuildingManagement -Environment tdd -Enabled:false
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Show
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Set -Name BuildingManagement -Environment tdd -Enabled:true
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Show
```

`-Action Show` prints each toggle and the stored `tdd`, `uat`, and `prod` row (on or off). It does not write. After the first command, Show includes `BuildingManagement` with `tdd off`. After the third, that row is `tdd on`.

`-Enabled` accepts `true`, `false`, `on`, `off`, `1`, and `0`. Quoted `'$true'` and `'$false'` select those same values. `-Enable` and `-Disable` flip with no value. The same shape turns Vendor management off in uat, then reads it back:

```text
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Set -Name VendorManagement -Environment uat -Disable
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Show
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Set -Name VendorManagement -Environment uat -Enable
```

From pwsh, `-Enabled $true` and `-Enabled $false` still bind. Set refuses a toggle that has not been created yet. Set and Ensure refuse a write when the stored toggle is still on the legacy targeting model.

5. When the UI process is evaluating live flags, refresh the site. No redeploy is required for the flip itself. A short cache can take a few seconds. Confirm with `GET /api/features/flags` on that environment's UI: the slug is true or false with the row you set. Providers below the minimum for rules will not follow the flip.
6. The client identifier reaches the running container on the next `ui` release after the system configuration that creates the Octopus variables and inlines `scripts/update-deployable.ps1` is applied (secret `OCTOPUS_FEATURES_CLIENT_IDENTIFIER` must already hold the JWT). When the UI process evaluates live flags, a flip changes `GET /api/features/flags` with no new image; that also proves egress to `https://features.octopus.com`. A missing client identifier stays off.

To put a demo back: the same environment switch off, or `-ResetDefaults`.

## Still manual

- Running Ensure (or the UI create) against `https://clearmeasure.octopus.app`. This repository does not hold an Octopus credential, and the agent that added the script did not call the API.
- Upgrading the project from legacy targeting to rules in the Octopus UI when that is still pending. This repository's script does not call the upgrade API and does not click Upgrade.
- The service-account dispatch above, if you use the workflow rather than a user key.
- Setting repository secret `OCTOPUS_FEATURES_CLIENT_IDENTIFIER` (name only) so the next system apply creates the Octopus variables on `cmdemo1-ui`.
- Applying the system configuration, then creating a `ui` release, so Update deployable writes `Octopus__FeatureFlags__ClientIdentifier`. The script is in this repository; the release is what puts the variable on the container app.
- A live flip in tdd to confirm `GET /api/features/flags` follows the row (and that the container can reach `https://features.octopus.com`).
- If the script's slug is not the name, recording that printed slug for the app lookup.

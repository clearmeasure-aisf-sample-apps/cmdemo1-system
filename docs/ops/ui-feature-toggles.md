# cmdemo1-ui feature toggles

Building management and vendor management are Octopus feature toggles on project **cmdemo1-ui** (`Projects-981`) in space **cmdemo1-demo** (`Spaces-355`). The API is `/api/Spaces-355/projects/Projects-981/featuretoggles`. The project UI may label that screen **Feature Flags**. This runbook calls them toggles.

| Toggle | Slug the script requests | tdd | uat | prod | Flag default |
|---|---|---|---|---|---|
| `BuildingManagement` | `BuildingManagement` | on | off | off | off |
| `VendorManagement` | `VendorManagement` | on | off | off | off |

The app evaluates the **slug**. The script asks Octopus to use the name as the slug. If Octopus assigns a different slug, the script prints it: that printed slug is the evaluation key, and [cmdemo1-workorders#1466](https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/1466) has to use it.

`tdd` stays on so Buildings and Vendors acceptance keeps passing once the app reads the toggles. `uat` and `prod` stay off until someone flips them for a demo. An environment with no row uses the flag default, which is off. A missing client identifier also fails closed in the app.

On means the surface is available. Off hides it and rejects the call.

| Toggle | On | Off, and still available |
|---|---|---|
| `BuildingManagement` | Nav **Buildings & Rooms**, `/admin/buildings`, building-room summary reads | Work order building text, the Open by Building report |
| `VendorManagement` | Vendors on Teams & Vendors, vendor commands and queries, MCP vendor tools | Waiting on a vendor, the teams portion of that page |

## What does not apply them

`octopus/` is Terraform provider `OctopusDeploy/octopusdeploy` **1.20.0**, which has no feature-toggle resource. Job `system` (`octopus-apply`) does not create these toggles and does not put a flipped environment back. Do not copy the on/off values into `system.json` `settings`: those are container environment variables, not feature flags, and they would ship only on a system deployment.

The client identifier is the Octopus variable `Octopus.FeatureToggles.ClientIdentifier`. It is a credential for the flag service. Do not write it into git, `system.json`, an issue, or a workflow log. `scripts/update-deployable.ps1` writes it onto the UI container app as `Octopus__FeatureFlags__ClientIdentifier` when the variable has text and the deployable is `ui`. Octopus inlines that script when the system configuration is applied. A `ui` release created after that apply is the one that injects it. A project without the variable is unchanged. Until the app runtime ships ([cmdemo1-workorders#1466](https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/1466)), a flip changes Octopus only. `GET /api/features/flags` will not follow the toggle.

## Create

No API key is stored in this repository. The script reads `OCTOPUS_API_KEY`, or `OCTOPUS_ACCESS_TOKEN` from `OctopusDeploy/login`. Put the key in the environment. Do not pass it as an argument (shell history and process listings keep arguments).

From a checkout of this repository, with no credential, this prints the create and does not call Octopus:

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -WhatIf
```

With a credential that can edit feature toggles on `cmdemo1-ui`:

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1
```

Ensure creates a missing toggle at the defaults above. Running it again does not turn `uat` or `prod` back off after a flip. An environment that is missing from an existing toggle is added at the default. `-ResetDefaults` is the way back to the table (phases already stored on an environment stay):

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -ResetDefaults
```

After this workflow is on `main`, Actions → **ui-feature-toggles** → Run workflow runs that same Ensure as the system's Octopus service account (`OctopusDeploy/login`, GitHub environment `octopus`). It does not run on push, so a merge does not reset a demo flip. If the run stops with 403, that account can read the project and cannot edit feature toggles: run the script as a user who can. If Octopus answers 404, the instance is not serving `/featuretoggles` on this project. Create the two toggles in the UI instead (next section) with the same names and the same on/off values, and leave the toggle default off.

Read what is stored:

```pwsh
pwsh -NoProfile -File scripts/ensure-ui-feature-toggles.ps1 -Action Show
```

## Flip

1. Open project `cmdemo1-ui` in space `cmdemo1-demo`: [cmdemo1-ui](https://clearmeasure.octopus.app/app#/Spaces-355/projects/Projects-981).
2. Open **Feature Flags**, then `BuildingManagement` or `VendorManagement`.
3. Turn the environment row on or off (`tdd`, `uat`, or `prod`). Save. Octopus publishes the manifest on save. This is not a release and not a new container image.
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

From pwsh, `-Enabled $true` and `-Enabled $false` still bind. Set refuses a toggle that has not been created yet.

5. When the UI process is evaluating live flags, refresh the site. No redeploy is required for the flip itself. A short cache can take a few seconds. Confirm with `GET /api/features/flags` on that environment's UI: the slug is true or false with the row you set.
6. The client identifier reaches the running container on the next `ui` release after the system configuration that inlines `scripts/update-deployable.ps1` is applied. Until [cmdemo1-workorders#1466](https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/1466) has shipped, stop after the save. The row in Octopus is the record of the flip. The running app does not read it yet, and a missing client identifier stays off once it does.

To put a demo back: the same row off, or `-ResetDefaults`.

## Still manual

- Running Ensure (or the UI create) against `https://clearmeasure.octopus.app`. This repository does not hold an Octopus credential, and the agent that added the script did not call the API.
- The service-account dispatch above, if you use the workflow rather than a user key.
- Applying the system configuration, then creating a `ui` release, so Update deployable writes `Octopus__FeatureFlags__ClientIdentifier`. The script is in this repository; the release is what puts the variable on the container app.
- The OpenFeature runtime ([cmdemo1-workorders#1466](https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-workorders/issues/1466)). Without it, the toggles have no live effect on the UI, the API, or MCP.
- If the script's slug is not the name, telling issue 1466 the slug `Show` printed.

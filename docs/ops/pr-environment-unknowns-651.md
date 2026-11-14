# Spike #651: PR-environment unknowns (measured and blocked)

**Issue:** [clearmeasure-aisf-sample-apps/cmdemo1-system#651](https://github.com/clearmeasure-aisf-sample-apps/cmdemo1-system/issues/651)  
**Measured on:** 2026-11-14 (UTC)  
**Method constraints:** read-only evidence from this repository, `cmdemo1-workorders` GitHub Actions, public Octopus/Azure docs, and live public health URLs. No Azure resources were created, changed, or resized. No money was spent beyond what already runs.

**Credential note for this cloud-agent run:** `CLOUD_AGENT_INJECTED_SECRET_NAMES` held only `GITHUB_TOKEN`, `GH_PROJECT_TOKEN`, and `CM_AI_OPS_BOT_GH_TOKEN`. No Azure service-principal client secret and no Octopus API key were present in the environment, so Azure Resource Manager and Octopus Deploy APIs were not callable. Octopus `GET /api/spaces` returned HTTP 401 without a key. Numbers below are therefore only what those sources can prove.

**Done-when status:** not complete. Several scope items still need Jeffrey's yes on #652/#653 (or injected read-only Azure/Octopus credentials plus a controlled experiment that does not create live pool Azure resources). This report uses **Refs #651**, not Closes.

---

## Summary

| Unknown | Status | Headline |
|---|---|---|
| Database copy time in elastic pool | **Unmeasured** | No elastic pool / template DB exists yet (`infra/modules/sql.bicep` is per-environment Basic/Serverless). Needs #653 apply. |
| Revision-ready + deploy step (migrate/swap/verify) on 1 vCPU / 2 GiB | **Unmeasured** | Live apps are 0.5 vCPU / 1 GiB (`system.json` `appCpu`). Needs a 1/2 GiB slot (#653) plus Octopus task timings. |
| App + elastic-pool load at 48 browser workers | **Unmeasured** | Would stress tdd (or a pool slot) beyond today's Smoke/12-worker practice. Needs a deliberate load run and Jeffrey's yes. |
| Idle vs active Container Apps billing | **Partially evidenced** | Billing rules + app shape strongly suggest warm `minReplicas: 1` slots stay on the **active** meter; idle/active $ rates for this app were not read from Cost Management. |
| Serial lane length, video/trace overhead, remote vs local at scale | **Partially measured** | Serial class seconds and local CI shard walls measured; remote-at-48 and video-on overhead not run. |
| Native ephemeral channel slot reuse | **Docs-confirmed, not space-measured** | Octopus docs say a fixed name reuses the environment; this space has no ephemeral channel yet and no API key to observe it. |
| Container Apps core quota (shared with tdd/uat) | **Unmeasured (subscription)** | Public default/docs only; `cae-cmdemo1-tdd` usages API not readable without Azure SP. |
| Publish-only image job time | **Measured** | Pack→push **112–179 s** (n=21), budget 180 s; no breach in sample. |
| Octopus task start on a slot | **Unmeasured** | Needs Octopus API + a slot deployment. |

---

## 1. Publish-only image job time — **measured**

**Budget (issue):** 3:00 (180 s).

**How obtained:** GitHub Actions workflow `Publish image` in `cmdemo1-workorders` (`.github/workflows/publish-image.yml`). Duration is the workflow's own meter: step `Record publish start` → step `Build and push the PR image` completed (pack start through image pushed; packages artifact uploads first). Only runs where `Compile and package (no tests)` succeeded were counted (skipped/no-PR publishes excluded).

**Sample:** 21 successful publishes from the 50 most recent workflow runs on 2026-11-14.

| Stat | Seconds |
|---|---|
| min | 112 |
| p50 | 161 |
| p90 | 174 |
| max | 179 |
| average | 154.6 |
| breaches of 180 s | **0 / 21** |

Example runs: `43639922674` (179 s), `43638845632` (142 s), `43638058465` (169 s), `43637440365` (151 s).

**Note:** The separate job `Publish PR packages to GitHub Packages` is after the image is available and is outside the 180 s meter the workflow reports.

---

## 2. Serial lane length, local shard times, video/trace overhead — **partial**

### 2a. Serial lane (class seconds) — **measured from repo catalogs**

**Sources:**

- `cmdemo1-workorders` `src/AcceptanceTests/acceptance-serial-lane.json` (3 fixtures)
- Class durations: `acceptance-durations.json` for two fixtures; `AccessibilityAxeTeamsTests` is listed in the serial catalog but **absent** from `acceptance-durations.json`, so its **13.7 s** comes from `acceptance-shards.json` `x64Seconds` (same measurement family: TRX class totals)

| Fixture | Seconds | Source |
|---|---|---|
| `App.AccessibilityAxeTeamsTests` | 13.7 | `acceptance-shards.json` x64Seconds |
| `TestUsers.AcceptanceTestEmployeesTests` | 80.0 | `acceptance-durations.json` (noted there as estimate for #1638) |
| `WorkOrders.WorkOrderSaveThenAssignPersistenceTests` | 19.9 | `acceptance-durations.json` |
| **Sum (workers = 1)** | **113.6** | sequential lower bound for the serial lane |

`Invoke-PrEnvironmentAcceptanceLane.ps1 -Lane Serial` forces `NumberOfTestWorkers=1` and filter `TestCategory==SerialLane`.

### 2b. Local parallel acceptance wall time (today's CI, not 48 workers) — **measured**

**Source:** `cmdemo1-workorders` Build run `43638872409` (master, 2026-11-14), jobs `Acceptance Tests [shard N/6]` (x64 SQL, `NumberOfTestWorkers=4` per `AcceptanceTests.runsettings` / `acceptance-shards.json` `"workers": 4`).

| Shard | Job wall (s) |
|---|---|
| 1 | 394 |
| 2 | 285 |
| 3 | 480 |
| 4 | 374 |
| 5 | 301 |
| 6 | 298 |
| **Critical path (max shard)** | **480 s (~8.0 min)** |

These are **local** suite runs (Build starts the app on the runner), not remote-against-slot.

### 2c. Planned 12×4 packing (repo math, not a live 48-worker run) — **computed from measured class seconds**

Using `Get-DurationShardAssignment.ps1` logic (greedy longest-first into 12 shards, serial fixtures excluded) on `acceptance-durations.json` as of master:

- Parallel fixtures: 74 classes, **4073.7** summed class-seconds
- Heaviest shard class-seconds: **349.7** (LoginTests alone)
- Naïve wall estimate at 4 workers: 349.7 / 4 ≈ **87 s** of test CPU time — **not** a measured remote wall clock (excludes browser startup, network, data load, and contention)

### 2d. Video / Playwright trace overhead — **not measured as a delta**

**Evidence of always-on tracing today:**

- `BrowserContextFactory` always calls `Tracing.StartAsync` with `Screenshots = true`, `Snapshots = true`, `Sources = true`
- Every test tear-down stops tracing to `playwright-traces/...zip`

There is **no** measured A/B (trace on vs off, or video on vs off) in CI. Private Azure video storage (14-day expiry) does not exist yet (plan / #653). **Blocker for a number:** run the same shard twice with tracing/video toggled, against the same host, and diff wall time and artifact size. That is a test-runner experiment; it does not require pool Azure resources, but it does need a deliberate Actions or local run (compute cost on runners only).

### 2e. Remote vs local per-test time at scale — **unmeasured**

- Local class seconds: `acceptance-durations.json` (`measuredFrom` GitHub Actions run `43125446701`, 2026-11-12)
- Remote today: Octopus tdd step runs **Smoke only** (`system.json` `ui.acceptanceTestsFilter` = `TestCategory=Smoke`). Repo has **9** `[Category("Smoke")]` attributes. Issue text cites **12 workers** for that Smoke run; git sets `AcceptanceTests.Workers` from `acceptanceTestsWorkers` (unset → `0` → auto-size in `run-acceptance-tests.ps1`). The live Octopus variable value was not readable without an API key.
- **Blocker for remote-at-48:** a full (or representative) remote suite against a slot/host with 12 runners × 4 workers, plus TRX export — needs a pool slot or Jeffrey's yes to load tdd, and Octopus/Actions log access for timings.

---

## 3. Idle vs active Container Apps billing — **partial**

### Measured / observed without creating resources

1. **Current spend (Cost Management snapshot already published by the system):** `status` branch `cost.json`, generated `2026-11-14T06:45:43Z`, currency USD, as-of `2026-11-13`:

   | Scope | Month to date |
   |---|---|
   | Whole system | 195.66 |
   | tdd Azure Container Apps | 76.37 |
   | uat Azure Container Apps | 27.63 |
   | prod Azure Container Apps | 51.02 |

2. **App shape (repo + live health):**
   - `ui` is **not** `alwaysOn` in `system.json`; `infra/modules/containerapps.bicep` sets `minReplicas: 0` when `alwaysOn` is false, `maxReplicas: 1`, CPU from `appCpu` (**0.5** in tdd/uat/prod).
   - tdd database catalog shows NServiceBus SQL-transport tables (`nServiceBus.UI.Server`, delayed, error, etc.).
   - Live tdd `/_healthcheck/detailed` (2026-11-14): Healthy; process thread count **32**; DataAccess and LlmGateway checks present — the process is doing real work when a replica is up.

3. **Microsoft idle rules (public docs, not a $ meter):** [Billing in Azure Container Apps](https://learn.microsoft.com/en-us/azure/container-apps/billing) — idle rates apply only when `minReplicas > 0`, the revision is at that minimum, and each replica has started, is not serving HTTP, uses **&lt; 0.01 vCPU**, and receives **&lt; 1,000 bytes/s** network. Otherwise the **active** rate applies. Scale-to-zero incurs no vCPU/GiB charge.

### Implication for the ~$200/month / 2 warm slots decision

Warm shadow slots are planned as **1 vCPU / 2 GiB**, `minReplicas: 1`. With an NServiceBus SQL-transport endpoint and background work in-process, replicas are **unlikely to stay under the idle thresholds**, so budget math should assume **active** Consumption rates for warm slots — but this spike did **not** read the subscription's idle vs active meter quantities or unit prices from Cost Management.

### Blocker for a measured idle/active split

- Inject Azure SP credentials into the agent (or run Cost Management / Usage Details query as `cm-ai-ops-bot`).
- Preferably one warm slot after #652/#653 (or temporarily set an existing app to `minReplicas: 1` — that **changes** live Azure and is out of scope here) and compare meter `Idle` vs `Active` vCPU-seconds over a quiet window.

---

## 4. Container Apps core quota (shared with tdd + uat) — **unmeasured for this subscription**

**Plan stress:** 8 slots × 3 replicas × 1 vCPU = **24 cores** of Consumption demand in one managed environment, plus whatever tdd/uat already use.

**Repo / inventory evidence (not quota):**

- tdd and uat container apps share managed environment `cae-cmdemo1-tdd` (`containers.json` on `status`, 2026-11-14).
- Current sized demand if both `ui` apps run one replica: **0.5 + 0.5 = 1.0** Consumption cores (plus any jobs on the D4 dedicated profile in that environment).
- Public Microsoft guidance: Managed Environment Consumption Cores are **per managed environment**; defaults vary by subscription (docs/samples show limits such as 10–100). That is **not** this subscription's limit.

**Blocker:** Azure login as read-only SP and:

```text
GET .../Microsoft.App/managedEnvironments/cae-cmdemo1-tdd/usages
```

(or Portal Quota page for that environment). No SP secret was available in this run (`az` was also not installed). Creating a new pool environment (#653) would need its own usages read after create.

---

## 5. Database copy time inside an elastic pool — **unmeasured**

**Why:** There is no elastic pool and no template database in Azure for cmdemo1 today. `infra/modules/sql.bicep` provisions a **single** database per environment (Basic or serverless GP), not `CREATE DATABASE … AS COPY OF` inside a pool. `environments/tdd/database.json` shows **17** tables and **2631** total rows (generated 2026-11-14) — size context only.

**Blocker:** After Jeffrey's yes on #653 (and identities #652 as needed):

1. Apply `stack-cmdemo1-pool` with Standard 50 eDTU elastic pool + `sqldb-cmdemo1-pool-template`.
2. Time `CREATE DATABASE [slot-N] AS COPY OF [sqldb-cmdemo1-pool-template]` (or the Bicep/ARM equivalent) from start to online, repeated enough for a range.
3. Do not use the production/tdd user databases as the copy source for the experiment without an explicit yes (data and DTU impact).

---

## 6. Revision-ready time and combined deploy step (1 vCPU / 2 GiB) — **unmeasured**

**Target (issue):** deploy step **2:45**, no extra firewall hop, one Azure sign-in.

**Why unmeasured at the planned size:**

- Live `ui` apps are **0.5 vCPU / 1 GiB**, `maxReplicas: 1` (`system.json` `appCpu`, `containerapps.bicep`).
- Octopus step timings (Migrate / Update deployable / Verify / Acceptance) require the Octopus API or UI; no API key in this environment.
- Proxy only (not the Done-when metric): GitHub `Release` for 2.4.2388 finished ~`2026-11-14T20:52:37Z`; tdd process start observed later via `/_healthcheck/detailed` — that gap mixes queue, migrate, revision, verify, and acceptance and is **not** a clean deploy-step measurement on 1/2 GiB.

**Blocker:**

1. A slot (or temporary resize) at **1 vCPU / 2 GiB** — #653 / Jeffrey's yes (resize of tdd would change live Azure; prefer a pool slot).
2. Octopus API key (read) to pull task step start/complete for migrate + update + verify (and revision-ready from Update deployable logs / Container Apps revision events).
3. Optionally disable acceptance on that experiment release so the 2:45 meter matches “migrate, swap, verify” only.

---

## 7. App and elastic pool load at 48 browser workers — **unmeasured**

**Configured intent (repo):** `Invoke-PrEnvironmentAcceptanceLane.ps1` defaults `ShardCount = 12`; runsettings workers = 4 → **48** browsers when all parallel shards run. Issue: tdd has only exercised Smoke (~9 tests) at ~12 workers.

**Why not run here:** A 48-worker remote run against tdd would contend with the shared demo environment and SQL Basic DB; against a pool it needs #653. Either path spends runner + Azure capacity beyond “what already runs.”

**Blocker:** Jeffrey's yes for a scheduled load window **or** a warm pool slot, then capture:

- App CPU/memory and HTTP latency (Container Apps metrics / App Insights)
- Elastic pool eDTU and DTU %
- Pass/fail and wall time of the 12 parallel shards + serial lane

---

## 8. Native ephemeral channel slot reuse — **docs-confirmed, not measured in Spaces-355**

**Octopus public behavior** ([Ephemeral environments](https://octopus.com/docs/projects/ephemeral-environments)): if the environment name template resolves to a name that **already exists**, Octopus **reuses** that environment and does not provision a new one. Custom fields can feed the template (e.g. `pool-#{Octopus.Release.CustomFields[Slot]}`). Per-slot names from `#{Octopus.Environment.Name}` remain valid for variable scoping under a parent environment.

**This space:** `octopus/` Terraform has **no** ephemeral channel / parent-environment resources today. Without an Octopus API key, existing channels/environments in `Spaces-355` could not be listed.

**Blocker for a measurement (not an Azure #653 apply, but still a live Octopus change):**

1. Octopus API key (read/write as needed) available to the operator/agent via env vars.
2. Jeffrey's yes to create (or use) a **parent** environment, an **ephemeral channel** with template `pool-#{Octopus.Release.CustomFields[Slot]}`, and fixed child env names `pool-1` … `pool-8` (can be empty of Azure targets at first).
3. Create two releases with the same `Slot` custom field; record whether the second increments environment count or redeploys the same environment id (API: environments list + deployment.EnvironmentId).

Fallback already decided if reuse fails: 8 permanent pool environments.

---

## 9. Octopus task start on a slot — **unmeasured**

**Budget (issue):** 0:20.

**Blocker:** Octopus API key + at least one deployment into a pool/slot environment; measure `QueueTime` / time from release created (or deploy requested) to first step executing. No slot and no API key in this run.

---

## Credential and safety checklist used

- Did not create/apply/change Azure resources; did not open #652/#653 applies.
- Did not print secret values; only secret **names** and presence.
- Did not loosen tests, checks, or gates.
- Did not merge.

## What would make Done-when true

Re-run (or extend) this spike when:

1. Azure SP env vars for `cm-ai-ops-bot` are injected (quota + cost meters + optional revision events).
2. Octopus API key env var is injected (task timings, ephemeral reuse observation).
3. Jeffrey explicitly approves #652/#653 (or a narrower experiment) for elastic-pool copy timing, 1/2 GiB revision/deploy timing, warm-slot idle billing, and/or 48-worker load.

Until then, keep this issue open and track progress with **Refs #651**.

# Pull-request pool stack (`stack-cmdemo1-pool`)

Desired state of the warm/cool pull-request slots: one Standard 50 eDTU elastic pool, template database
`sqldb-cmdemo1-pool-template`, eight slot apps and databases (`pool-1` .. `pool-8`, two warm for shadow mode), and
private storage for videos and traces (14-day expiry).

## Apply only after Jeffrey's yes

Writing and merging this code is fine. **Do not** create the live Azure resources until Jeffrey's explicit yes is
recorded (issue #653). Filing the issue is not that yes.

This stack is **not** applied by `scripts/apply-environment.ps1`, by Octopus `<slug>-system`, or by any pipeline that
auto-applies environments. When Jeffrey has said yes, an operator applies it once by hand as the nonprod deploy
identity, for example:

```bash
az stack group create \
  --name stack-cmdemo1-pool \
  --resource-group rg-cmdemo1-nonprod \
  --template-file infra/pool/main.bicep \
  --parameters sqlAdminPassword=<generated> deployPrincipalId=<id-cmdemo1-deploy-nonprod principal id> \
  --action-on-unmanage deleteResources \
  --deny-settings-mode denyWriteAndDelete \
  --deny-settings-excluded-principals <id-cmdemo1-deploy-nonprod principal id> \
  --yes
```

Until then, validation is local and in `env-checks` only: `az bicep build` of this template and
`scripts/test-pool.ps1` (what-if-free structural checks; no Azure write).

## Layout

| Path | What |
|---|---|
| `main.bicep` | Stack entry; reads `system.json` `pool` |
| `modules/sql.bicep` | SQL server, elastic pool, template DB, slot DBs |
| `modules/slots.bicep` | Container Apps environment and slot apps |
| `modules/vault.bicep` | Pool vault (SQL secrets) |
| `modules/artifacts.bicep` | Private videos/traces storage, 14-day lifecycle |

Shadow defaults in `system.json` `pool`: 8 slots, 2 warm, 50 eDTU, 1 vCPU / 2 GiB, maxReplicas 3 on HTTP concurrency.

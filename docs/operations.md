# Operations and troubleshooting

## How ODGO runs

| Component | Schedule | What it does |
|---|---|---|
| Agent task `\ODGO\Collect Gateway Logs` | Every 15 minutes, up to 2 minutes random delay | Uploads new data, a manifest per run and run telemetry (a heartbeat, even when there's nothing new) |
| `nb_gwmon_ingest` | Every 6 hours | Bronze ingest, then Silver transform, then Gold build |
| `nb_gwmon_maintenance` | Once a day | Retention of files and tables, `OPTIMIZE` (V-Order on Gold), `VACUUM`, staging and orphan cleanup, then validation checks |
| Semantic model | Direct Lake automatic updates | Picks up new Gold table versions without a scheduled refresh |

Data latency is the sum of the agent interval, the wait for the next ingest run and the duration of that run, which
depends on the data volume and the capacity. No latency measurements are published.

## Monitoring

* **Ingestion Health page** of the report: for each server, the upload status (*OK*, *Late* after
  `gold.lateAfterMinutes` without a processed heartbeat, *Missing* after `gold.missingAfterMinutes`, *Failing* when the
  last run failed; 8 and 24 hours by default), the last upload and the last processed file. Cards show pending
  segments, rejected records, quarantined files, failed processing runs, the ingestion latency and the uploaded volume.
* **Ingestion Details page**: issues (rejected records, quarantined files, missing segments, failures, schema drift),
  agent runs and processing runs.
* **Monitoring hub** in Fabric: notebook runs with their output.
* **Alerts**: set an alert on the *# Servers (Missing Uploads)* or *# Failed Processing Runs* card (Power BI alerts or
  [Fabric Activator](https://learn.microsoft.com/fabric/real-time-intelligence/data-activator/activator-introduction)).

## Agent

| Task | How |
|---|---|
| Test the configuration, identity and OneLake access | `& "$env:ProgramFiles\ODGO\Invoke-GatewayLogCollection.ps1" -Test` |
| Run now | `Start-ScheduledTask -TaskPath '\ODGO\' -TaskName 'Collect Gateway Logs'` |
| See what would be uploaded | `Invoke-GatewayLogCollection.ps1 -PlanOnly` (no upload, no state change) |
| Read the logs | `%ProgramData%\ODGO\logs\agent-yyyyMMdd.jsonl`, one JSON object per line: `Get-Content <file> \| ConvertFrom-Json \| Where-Object level -ne 'Debug'` |
| Exit codes | `0` succeeded, `1` partially succeeded (retried next run), `2` failed, `3` configuration error, `4` another run is in progress |
| Rotate the client secret | Create a new secret on the app registration, then run `& "$env:ProgramFiles\ODGO\Install-Agent.ps1" -UpdateSecret` on each server. Delete the old secret afterwards |
| Change a setting | Edit `%ProgramData%\ODGO\config\config.json` ([configuration.md](configuration.md#agent-configuration)), then run `-Test` |
| Upgrade | Run the `Install-Agent.ps1` of the new version without parameters ([setup.md](setup.md#upgrade)) |
| Remove | `Uninstall-Agent.ps1` (add `-RemoveData` to delete configuration, secret, state and logs) |

**Add a gateway server:** install the agent with the same command ([setup.md](setup.md#3-install-the-agent-on-each-gateway-server)).
With managed identities, first add the new server's identity to the workspace. The server appears on the
*Ingestion Health* page after the next ingest run (run `nb_gwmon_ingest` yourself to see it sooner). Gateways are
identified by their gateway ID, so clusters with members on several servers are grouped automatically.

**Decommission a gateway server:** uninstall the agent (`Uninstall-Agent.ps1 -RemoveData`), then add the server name
or ID to `gold.retiredServers` in `processing.json`. Otherwise a silent server stays *Missing* on purpose, so that a
real outage never disappears from view. Its gateway becomes *Inactive* after `gold.inactiveAfterDays` without data;
historical data is kept according to the retention settings.

## Backfill and reprocessing

| Need | Action |
|---|---|
| Upload older logs on a new server | Set `collection.initialBackfillDays` before the first run. Only the log files still on disk can be uploaded |
| Re-upload everything still on disk from a server | Stop the task, delete `state\checkpoint.json` and `state\checkpoint.json.bak`, start the task. Silver and Gold deduplicate by content key, so nothing is counted twice |
| Re-ingest landing files (for example after a parser fix) | Run `nb_gwmon_ingest` with `reprocess_from` / `reprocess_to` (upload dates). The raw files must still exist (`retention.rawDays`) |
| Rebuild Silver from Bronze | Run `nb_gwmon_ingest` with `rebuild_from_batch` set to a Bronze `ingest_batch_id`, or `0` for everything |
| Rebuild Gold | Run `nb_gwmon_ingest` with `rebuild_gold = True` |
| Catch up after an outage | Nothing to do: agents keep the data on the servers and upload it in budgeted runs. For an outage longer than `landing.manifestLookbackDays`, run `nb_gwmon_ingest` once with `lookback_days` covering the outage |

Invalid manifests and segments (bad JSON, size or SHA-256 mismatch, unexpected path, oversized records) are copied
to `Files/gateway-monitor/processing/quarantine/`, listed in `ops.quarantined_files` and on the *Ingestion Details*
page. After fixing the cause, re-ingest them with `reprocess_from`.

## Retention, capacity and recovery

* **Retention** is set in `processing.json` (`retention.*`) and applied once a day by `nb_gwmon_maintenance`. Run it
  with `dry_run = True` to see what would be deleted.
* **Capacity.** No consumption measurements are published. Consumption comes mainly from the notebook runs (every 6
  hours by default) and Direct Lake queries. Watch the run durations in *Processing Runs* and the
  [Capacity Metrics app](https://learn.microsoft.com/fabric/enterprise/metrics-app). Scheduling `nb_gwmon_ingest` more
  often gives fresher data but consumes more; lowering `gold.windowDays` reduces consumption.
* **Recovery.** The definitions are in this repository: run the setup notebook in a new workspace, then run
  `Install-Agent.ps1 -WorkspaceId <new-id> -LakehouseId <new-id>` on each server. Uploads continue from the agents'
  checkpoints; to upload again what's still on the servers, reset the checkpoints (see
  [Backfill and reprocessing](#backfill-and-reprocessing)).

## Troubleshooting

Start with the tool that matches the layer:

| Layer | First check |
|---|---|
| Agent | `Invoke-GatewayLogCollection.ps1 -Test` on the server, then the agent log |
| Setup notebook | The error printed by the notebook: it names the step and what to check |
| Processing | Monitoring hub (notebook runs), the *Ingestion Details* page and `ops.processing_runs` |
| Report | The *Ingestion Health* page, the semantic model's refresh history |

### Agent

| Symptom | Cause | Fix |
|---|---|---|
| Exit code 3, `Invalid agent configuration` | Unknown key (keys are camelCase), wrong GUID | The message lists each problem with its JSON path |
| Exit code 4 | A previous run is still running (large catch-up, hung process) | Runs stop starting uploads after `agent.maxRunMinutes`. Check the Task Scheduler history |
| `AADSTS7000215` or `AADSTS7000222` | Wrong or expired client secret | Create a new secret and run `Install-Agent.ps1 -UpdateSecret` |
| `AADSTS700016` or `AADSTS90002` | Wrong client ID or tenant ID | Run `Install-Agent.ps1 -TenantId … -ClientId …` with the right values |
| `Client secret file … not found` or `Cannot read the client secret` | No secret stored, or the file was copied from another server | Run `Install-Agent.ps1 -UpdateSecret` |
| Installer: `'…' is owned by …, not by SYSTEM, Administrators, you or the task identity` | The data folder already existed and was created or changed by another account, which could read the secret | Check the folder. Delete it, or make Administrators its owner with the `takeown` command in the message, then run the installer again |
| Installer: `The task identity '…' can't be resolved` | `-TaskUser`, or the identity of the existing scheduled task, isn't a valid group managed service account for this server | Pass `-TaskUser DOMAIN\name$` (check it with `Test-ADServiceAccount`) or `-TaskUser SYSTEM` |
| Managed identity: `… only on Azure VMs and Azure Arc-enabled servers` | The server has no managed identity | Use an app registration with a client secret |
| HTTP 401 or 403 from OneLake | The identity isn't Contributor of the workspace, the role was granted a few minutes ago, or a tenant setting is off | Check **Manage access**, wait a few minutes, check the tenant settings in [setup.md](setup.md#prerequisites) |
| HTTP 404 on the landing folder | Wrong workspace or lakehouse ID, or the setup notebook hasn't run `nb_gwmon_ingest` yet | Run `nb_gwmon_ingest` once, then check the IDs printed by the setup notebook |
| Timeouts, name resolution or TLS errors | Proxy required or endpoints blocked | Run `Install-Agent.ps1 -ProxyUrl http://proxy:port`. Allow `login.microsoftonline.com` and the OneLake endpoint. A TLS-inspecting proxy's root certificate must be trusted by the machine |
| `Gateway log folder … not found` | Gateway not installed, service name differs, or a group managed service account can't read the gateway service profile | Set `sources[].logPath` (and `reportPath`), or grant read access to the folder |
| A log type is never uploaded | Disabled type (`gateway-network` is off by default), files older than `initialBackfillDays` when first seen, `Report` folder moved, or personal-mode gateway | Enable the log type or set `reportPath`. To backfill, see [Backfill and reprocessing](#backfill-and-reprocessing) |
| New data arrives late | Small deltas wait for `minSegmentBytes` up to `maxSegmentAgeMinutes`; the last line of an active file waits until the file is settled | Expected. Lower the thresholds if needed |
| Exit code 1 (partial) | Locked file after retries, upload budget reached, or one failing file | The next run continues from the checkpoint. Persistent failures are in the agent log and in the run telemetry |

### Setup notebook

| Symptom | Fix |
|---|---|
| `This workspace isn't assigned to a Fabric capacity` | Assign a capacity in the workspace settings (**License info**) and run the notebook again |
| `… isn't an Object ID` or `couldn't give the Contributor role to …` | `agent_principal_id` must be the Object ID shown under **Enterprise apps**, not the Application (client) ID nor the Object ID shown under **App registrations**. Or leave it empty and add the identity in **Manage access** ([setup.md](setup.md#give-the-agents-access-to-the-workspace)) |
| Download of `source` fails | Fabric must reach GitHub. Otherwise set `source` to a `.zip` file the notebook can read |
| HTTP 403 while creating items or granting the role | You need the Admin or Member role on the workspace |
| Warning `Semantic model framing failed` | The model is framed again automatically when the Gold tables change; check its refresh history after the next ingest run |
| Every step succeeded but the report is empty | Normal until an agent has uploaded data and `nb_gwmon_ingest` has processed it (every 6 hours by default). To see the data sooner, run `nb_gwmon_ingest` yourself |

The setup can be run again safely: it updates the existing items, matched by name.

### Processing

| Symptom | Cause | Fix |
|---|---|---|
| *Missing Segment* issues | A manifest lists a segment that isn't in `raw/` (upload interrupted, or file deleted) | Agents replay their journal on the next run. Persistent cases: check retention and manual deletions |
| *Orphan File* issues | Raw files without a committed manifest after `landing.orphanAfterHours` | The next agent run publishes the manifest; otherwise maintenance removes orphans after retention |
| *Quarantined File* issues | Invalid manifest or segment | See `ops.quarantined_files.reason`, fix the cause, then reprocess |
| Many *Rejected Record* issues | A gateway update changed a log format, or implausible timestamps | Group `ops.rejected_records` by reason, check `ops.schema_drift`, and open an issue with a sanitized sample |
| Silver has data but the report doesn't | Outside `gold.windowDays`, excluded by `gold.gatewayInclude`, or log type not in `gold.logTypes` | Adjust `processing.json` and run `nb_gwmon_ingest` (with `rebuild_gold = True` for history) |
| Validation fails | A check exceeded its threshold (duplicates, orphans, freshness, too many Parquet files) | The notebook output lists the failed checks |
| Runs take longer and longer | Too many small files, or capacity throttling | Check that the maintenance runs succeed. Schedule the ingest less often or scale the capacity |

### Report

| Symptom | Cause | Fix |
|---|---|---|
| A server shows *Late* or *Missing* although its agent runs | Its telemetry isn't processed: `nb_gwmon_ingest` is failing, its schedule is off (Fabric turns a schedule off after about 10 consecutive failures, and a schedule expires when its owner hasn't signed in to Fabric for 90 days), or it runs less often than `gold.lateAfterMinutes` | Check the latest `nb_gwmon_ingest` runs and its schedule (run the setup notebook again to recreate it), then the agent log |
| A decommissioned server stays *Missing* | By design | Add it to `gold.retiredServers` |
| Visuals fail for some readers only | Single sign-on: those readers can't read the lakehouse | Bind the model to a fixed identity ([setup.md](setup.md#share-the-report)) |
| Visuals fail for everyone after growth | Direct Lake [guardrails](https://learn.microsoft.com/fabric/fundamentals/direct-lake-overview#fabric-capacity-requirements) of the capacity SKU; Direct Lake on OneLake doesn't fall back to DirectQuery | Check the maintenance runs, lower `gold.windowDays` or use a larger SKU |
| Times differ from the server's local time | Everything is stored in UTC | Each server's time zone and UTC offset are in the `Servers` table |
| New data doesn't appear | Automatic updates are off on the model, or the last framing failed | Turn automatic updates on, or set `semanticModel.reframeAfterGold` to `true`. Check the refresh history |

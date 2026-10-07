# Configuration reference

Every setting has a default, so a standard installation needs no configuration file editing:

| Settings | Where | Written by |
|---|---|---|
| [Setup notebook parameters](#setup-notebook-parameters) (optional) | First code cell of `ODGO_Setup` | You, before **Run all** |
| [Agent configuration](#agent-configuration) | `%ProgramData%\ODGO\config\config.json` on each gateway server | `Install-Agent.ps1` |
| [Processing configuration](#processing-configuration-processingjson) | `Files/gateway-monitor/config/processing.json` in `lh_gateway_monitor` | `nb_gwmon_ingest`, with the defaults, on its first run |
| [Gateway overrides](#gateway-overrides-gateway-overridesjson) (optional) | `Files/gateway-monitor/config/gateway-overrides.json` | You |

## Setup notebook parameters

The defaults suit most installations.

| Parameter | Default | Description |
|---|---|---|
| `source` | `main` branch archive on GitHub | ODGO version to install: the URL of a repository `.zip` (branch or release), or a `.zip` file or repository folder readable by the notebook |
| `ingest_interval_minutes` | `360` | How often `nb_gwmon_ingest` runs, in minutes (every 6 hours). Above 360, also raise `gold.lateAfterMinutes` (see [processing configuration](#processing-configuration-processingjson)) |
| `run_first_ingestion` | `True` | Run `nb_gwmon_ingest` once during the setup (creates the tables) and frame the semantic model |

`nb_gwmon_maintenance` runs once a day, between two runs of `nb_gwmon_ingest`. The schedules can also be changed later
in the schedule settings of each notebook.

## Agent configuration

`Install-Agent.ps1` writes only the values you pass to it, for example:

```json
{
  "target": { "workspaceId": "<workspace-id>", "lakehouseId": "<lakehouse-id>" },
  "authentication": { "mode": "ClientSecret", "tenantId": "<tenant-id>", "clientId": "<client-id>" }
}
```

Every other key takes the default listed below. To change a setting, edit the file as an administrator, then check
it with:

```powershell
& "$env:ProgramFiles\ODGO\Invoke-GatewayLogCollection.ps1" -Test
```

* Keys are camelCase. Unknown keys are rejected, so typos fail fast.
* Environment variables in paths, such as `%ProgramData%`, are expanded.
* Running `Install-Agent.ps1` again keeps your edits: it only changes the values passed as parameters.

### `environment`, `agent`, `server`

| Key | Default | Description |
|---|---|---|
| `environment` | `prod` | Label written to the landing paths (`raw/environment=<value>/…`) and to the `Environment` column of the model |
| `agent.stateDirectory` | `%ProgramData%\ODGO\state` | Checkpoint, journal, telemetry outbox, agent instance ID |
| `agent.logDirectory` | `%ProgramData%\ODGO\logs` | JSON-lines run logs `agent-yyyyMMdd.jsonl` |
| `agent.logLevel` | `Information` | `Debug`, `Information`, `Warning`, `Error` |
| `agent.logRetentionDays` | `30` | Local log retention |
| `agent.maxRunMinutes` | `45` | No new upload starts after this duration; the next run continues |
| `agent.checkpointRetentionDays` | `30` | Checkpoint entries of files not seen for this many days are removed |
| `agent.outboxMaxFiles` | `100` | Run telemetry documents kept locally while OneLake is unreachable |
| `server.name` | host name | Overrides the server name used in landing paths |
| `server.id` | first 16 hex characters of SHA-256(MachineGuid) | Override for cloned VMs that share a MachineGuid |

### `target`

| Key | Default | Description |
|---|---|---|
| `target.type` | `OneLake` | `OneLake`, or `LocalFolder` (writes the same layout to a folder, for tests) |
| `target.endpoint` | `https://onelake.dfs.fabric.microsoft.com` | Global endpoint. Alternatives: a regional endpoint `https://<region>-onelake.dfs.fabric.microsoft.com`, or the workspace FQDN for private links ([OneLake endpoints](https://learn.microsoft.com/fabric/onelake/onelake-access-api)) |
| `target.workspaceId` / `target.lakehouseId` | — | Workspace and lakehouse IDs (`-WorkspaceId` / `-LakehouseId`) |
| `target.rootFolder` | `Files/gateway-monitor/landing` | Landing root. Must match `landing.root` in `processing.json` |
| `target.localPath` | — | Folder of the `LocalFolder` target |

### `authentication`

| Key | Default | Description |
|---|---|---|
| `authentication.mode` | `ClientSecret` | `ClientSecret`, `ManagedIdentity` (Azure VM or Azure Arc-enabled server, detected automatically) or `None` (`LocalFolder` only) |
| `authentication.tenantId` / `clientId` | — | Tenant and app registration (`-TenantId` / `-ClientId`) |
| `authentication.clientSecretPath` | `%ProgramData%\ODGO\config\client-secret.dat` | Client secret encrypted with DPAPI (machine scope). Written by `Install-Agent.ps1`; it can only be decrypted on this server |
| `authentication.managedIdentityClientId` | — | User-assigned managed identity on an Azure VM (`-ManagedIdentityClientId`) |
| `authentication.authorityHost` | `https://login.microsoftonline.com` | Sovereign clouds |
| `authentication.resource` | `https://storage.azure.com/` | Token audience. OneLake accepts only the Storage audience |

### `network`

| Key | Default | Description |
|---|---|---|
| `network.proxyUrl` | — | Explicit HTTP proxy (`-ProxyUrl`), for example `http://proxy.contoso.com:8080`. The gateway's own proxy configuration isn't read |
| `network.proxyUseDefaultCredentials` | `true` | Authenticate to the proxy as the task identity |
| `network.timeoutSeconds` | `100` | Per request |
| `network.maxRetries` / `retryBaseDelaySeconds` / `retryMaxDelaySeconds` | `5` / `2` / `60` | Exponential backoff with jitter for 408, 429, 5xx and network errors. `Retry-After` is honored |
| `network.uploadChunkBytes` | `4194304` | DFS append size (64 KiB – 100 MiB) |

### `collection`

| Key | Default | Description |
|---|---|---|
| `collection.initialBackfillDays` | `7` | On first sight, files last written more than this many days ago aren't uploaded. Set 0 to upload only new data, or a large value to backfill history |
| `collection.minSegmentBytes` | `262144` | New data smaller than this waits for the next run, unless older than `maxSegmentAgeMinutes` or the file is settled |
| `collection.maxSegmentBytes` | `33554432` | Larger deltas are split into several record-aligned segments |
| `collection.maxSegmentAgeMinutes` | `60` | Pending data older than this is uploaded even if small |
| `collection.settleSeconds` | `300` | A file not written for this long is *settled*: its last complete record is released immediately. A file not written for 60 minutes also releases an unterminated last line |
| `collection.maxBytesPerRun` / `maxSegmentsPerRun` | `1073741824` / `2000` | Per-run upload budget; the rest is uploaded by the next runs |
| `collection.lockRetryCount` / `lockRetryDelayMilliseconds` | `3` / `500` | Retries when a log file is locked |
| `collection.metadataRefreshHours` | `24` | Interval of the agent metadata snapshot (gateway version, cores, memory, OS) |
| `collection.logTypes.<type>` | built-in catalog | Per log type: `enabled`, `patterns`, `exclude` (see below) |

### `sources`

A source is one gateway installation on the server. Without `sources`, the default source monitors the gateway
service `PBIEgwService`. Declare one source per gateway on servers that run several gateways.

| Key | Default | Description |
|---|---|---|
| `sources[].name` | `default` | Unique name on the server (letters, digits, `.`, `_`, `-`) |
| `sources[].enabled` | `true` | |
| `sources[].logPath` | discovered | Gateway log folder. When null, it's discovered from the service account profile of `serviceName` (`…\AppData\Local\Microsoft\On-premises data gateway`) |
| `sources[].reportPath` | `<logPath>\Report` | Folder of the `*Report*.log` files |
| `sources[].serviceName` | `PBIEgwService` | Windows service used for discovery and status |
| `sources[].gatewayId` / `gatewayName` / `clusterId` / `clusterName` | discovered | Override the IDs and names read from `GatewayProperties.txt` and `GatewayClusters.txt` |
| `sources[].logTypes` | all enabled types | Restricts the log types collected for this source |

### Log types

| Log type | Files | Folder | Upload | Default |
|---|---|---|---|---|
| `gateway-errors` | `GatewayError*.log` | log folder | incremental (trace records) | on |
| `gateway-info` | `GatewayInfo*.log` | log folder | incremental | on |
| `gateway-network` | `GatewayNetwork*.log` | log folder | incremental | **off** (verbose) |
| `mashup` | `Mashup*.log` (except `MashupContainerProfiles*`) | log folder | incremental (JSON lines) | on |
| `mashup-container-profiles` | `MashupContainerProfiles*.log` | log folder | snapshot | on |
| `query-start-report` | `QueryStartReport*.log` | Report | incremental (CSV) | on |
| `query-execution-report` | `QueryExecutionReport*.log` | Report | incremental | on |
| `query-execution-aggregation-report` | `QueryExecutionAggregationReport*.log` | Report | incremental | on |
| `system-counter-aggregation-report` | `SystemCounterAggregationReport*.log` | Report | incremental | on |
| `gateway-properties` | `GatewayProperties.txt` | log folder | snapshot | on |
| `gateway-clusters` | `GatewayClusters.txt` | log folder | snapshot | on |
| `gateway-configuration` | `*ConfigurationProperties.json` | log folder | snapshot | on |

Example: collect the network logs with a narrower pattern.

```json
"collection": { "logTypes": { "gateway-network": { "enabled": true, "patterns": ["GatewayNetwork2*.log"] } } }
```

The four `Report` files come from the gateway's [performance logging](https://learn.microsoft.com/data-integration/gateway/service-gateway-performance).
The feature is labelled public preview but is on by default for gateways in standard mode; personal mode doesn't
have it. If `ReportFilePath` was changed in `Microsoft.PowerBI.DataMovement.Pipeline.GatewayCore.dll.config`, set
`sources[].reportPath` to the same folder. `QueryExecutionAggregationTimeInMinutes` and
`SystemCounterAggregationTimeInMinutes` (5 minutes by default) set the granularity of the aggregation reports.

## Processing configuration (`processing.json`)

`nb_gwmon_ingest` creates `Files/gateway-monitor/config/processing.json` with the defaults below on its first run.
Both notebooks read it at every run, so a change applies to the next run. To change it, download the file from the
lakehouse explorer, edit it and upload it again (or edit it with any OneLake-compatible tool). Missing keys keep their
defaults; invalid values stop the run with a message that lists them.

| Section | Key | Default | Description |
|---|---|---|---|
| `landing` | `root` | `Files/gateway-monitor/landing` | Landing root |
| | `manifestLookbackDays` | `3` | Date partitions scanned for new manifests and telemetry (notebook parameter `lookback_days` overrides it) |
| | `maxManifestsPerRun` | `5000` | Throttle for catch-up runs |
| | `maxSegmentAttempts` | `5` | Attempts before a listed but unreadable segment becomes a *Missing Segment* issue |
| | `orphanAfterHours` | `24` | Raw files without a committed manifest after this delay are reported as *Orphan File* |
| `bronze` | `maxRecordChars` | `1000000` | Longer records are rejected |
| | `dedupLookbackDays` | `7` | Window of the record-ID dedup check |
| `silver` | `extraColumnsMaxChars` | `8000` | Size of the JSON column that keeps unknown CSV columns (schema drift) |
| | `minEventYear` / `maxFutureMinutes` | `2015` / `1440` | Plausibility checks on event times (rejected records otherwise) |
| `gold` | `windowDays` | `180` | Days of history published to Gold and the model |
| | `logTypes` | `["gateway-errors","gateway-info"]` | Trace log types published to `gold.logs` (add `gateway-network` if collected) |
| | `maxLogTextLength` / `maxQueryTextLength` / `maxErrorTextLength` | `1000` / `1000` / `4000` | Truncation in Gold (Silver keeps the full text) |
| | `gatewayInclude` | `[]` | Optional allow-list of gateway IDs (empty = all) |
| | `retiredServers` | `[]` | Server IDs or names of decommissioned agents. They're removed from the *Ingestion Health* status (otherwise they stay *Missing*) |
| | `inactiveAfterDays` | `14` | Gateways without data for this long get `Status = Inactive` |
| | `expectedUploadIntervalMinutes` / `lateAfterMinutes` / `missingAfterMinutes` | `15` / `480` / `1440` | Thresholds of the *Upload Status* (OK, Late, Missing, Failing). The report compares the last processed heartbeat with the current time, so `lateAfterMinutes` must stay longer than the interval of `nb_gwmon_ingest`. If you schedule it more often, you can lower them to detect a silent server sooner |
| | `ingestionWindowDays` | `30` | History of the ingestion-health tables |
| | `calendarFutureYears` | `0` | Extra years in `gold.calendar` |
| `redaction` | `enabled`, `rules[]` | connection-string secrets, bearer tokens | Regex rules (`name`, `pattern`, `replacement`, `columns`) applied in Silver to the listed text columns |
| `retention` | `rawDays`, `manifestDays`, `telemetryDays`, `stagingDays`, `bronzeDays`, `silverDays`, `opsDays`, `quarantineDays`, `vacuumHours` | `30`, `90`, `90`, `2`, `30`, `400`, `400`, `90`, `168` | Applied by `nb_gwmon_maintenance`. `vacuumHours` can't be lower than 168 |
| `maintenance` | `optimizeLayers`, `vacuumLayers`, `optimizeRecentPartitionsOnly`, `recentPartitionDays` | all layers, `true`, `45` | `OPTIMIZE` (V-Order on Gold) and `VACUUM` |
| `semanticModel` | `name`, `reframeAfterGold` | `Gateway Monitor`, `false` | Explicit reframe at the end of the Gold build (also notebook parameter `reframe_semantic_model`) |
| `validation` | `failOnError`, `maxParquetFilesPerTable`, `freshnessMinutes` | `false`, `1000`, `480` | Thresholds of the validation checks run by `nb_gwmon_maintenance` |

### Notebook parameters

Scheduled runs use the defaults. For a manual run, change the parameters cell of the notebook and run it, or run
the notebook from a pipeline with parameters.

| Notebook | Parameter | Description |
|---|---|---|
| `nb_gwmon_ingest` | `lookback_days` | Days of manifests and telemetry to scan (0 = `landing.manifestLookbackDays`) |
| | `reprocess_from` / `reprocess_to` | Re-ingest segments uploaded between these dates (`YYYY-MM-DD`); the raw files must still exist |
| | `max_manifests` | Maximum manifests per run (0 = `landing.maxManifestsPerRun`) |
| | `rebuild_from_batch` | Reprocess Silver from the Bronze batches after this `ingest_batch_id` (`0` = everything) |
| | `rebuild_gold` | Recompute every Gold table of the window instead of the changed months only |
| | `reframe_semantic_model` / `semantic_model_name` | Reframe the semantic model at the end |
| `nb_gwmon_maintenance` | `dry_run` | List what would be deleted, without deleting or compacting anything |
| | `skip_optimize` / `skip_vacuum` | Skip a maintenance step |
| | `fail_on_error` | Fail the run when a validation check fails (also `validation.failOnError`) |

## Gateway overrides (`gateway-overrides.json`)

Optional. Non-null values override the discovered metadata in `gold.gateways`, for example to name a gateway or add
the cores of a server whose metadata snapshot isn't collected. Upload the file to
`Files/gateway-monitor/config/gateway-overrides.json`; the next Gold build applies it.

```json
{
  "schemaVersion": "1.0",
  "gateways": [
    { "gatewayId": "<gateway-id>", "gatewayName": "<gateway-name>", "clusterName": "<cluster-name>",
      "environment": "prod", "numberOfCores": 8, "description": "Primary node" }
  ]
}
```

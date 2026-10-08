# Data model

<!-- Generated from the table contracts of ODGO_Lib and the TMDL semantic model. -->

The Lakehouse `ODGO_Lakehouse` is schema-enabled: one schema per layer. Every table is a Delta table created
by the `ODGO_Ingest` notebook from the contracts below (additive evolution only). Times are UTC unless stated otherwise.

| Layer | Schema | Tables | Purpose |
|---|---|---|---|
| Bronze | `bronze` | 1 | Raw records exactly as uploaded by the agents, with ingestion metadata. Append-only, deduplicated by record id. |
| Silver | `silver` | 10 | Parsed, typed and normalized records per log family, redacted, deduplicated by content key. |
| Gold | `gold` | 16 | Star schema read by the Direct Lake semantic model (original pbigtwmonitor tables + ingestion health). |
| Ops | `ops` | 8 | Operational registries and run logs: manifests, segments, agent and processing runs, rejected and quarantined data, schema drift. |

## Semantic model

The semantic model `ODGO_Model` (Direct Lake on OneLake) reads these Gold tables:

| Model table | Lakehouse table |
|---|---|
| Agent Runs | `gold.ingestion_agent_runs` |
| Calendar | `gold.calendar` |
| Gateways | `gold.gateways` |
| Ingestion Issues | `gold.ingestion_issues` |
| Ingestion Uploads | `gold.ingestion_uploads` |
| Logs | `gold.logs` |
| LogsArtifactTrace | `gold.logs_artifact_trace` |
| Mashup Container Profile | `gold.mashup_container_profile` |
| Mashup Logs | `gold.mashup_logs` |
| Processing Runs | `gold.ingestion_processing_runs` |
| Queries | `gold.queries` |
| Queries - Datasources | `gold.query_datasources` |
| Requests | `gold.requests` |
| Servers | `gold.ingestion_servers` |
| System Counters | `gold.system_counters` |
| Time | `gold.time_of_day` |

Relationships (many-to-one from the fact column to the dimension key):

| From | To | Active | Cross-filter |
|---|---|---|---|
| Logs.GatewayId | Gateways.GatewayId | yes | single |
| Logs.Date | Calendar.Date | yes | single |
| Logs.TimeId | Time.TimeId | yes | single |
| Queries.TimeId | Time.TimeId | yes | single |
| 'Mashup Container Profile'.GatewayId | Gateways.GatewayId | yes | single |
| 'System Counters'.Date | Calendar.Date | yes | single |
| 'System Counters'.TmeId | Time.TimeId | yes | single |
| Queries.GatewayId | Gateways.GatewayId | yes | single |
| 'Mashup Logs'.Date | Calendar.Date | yes | single |
| 'Mashup Logs'.TimeId | Time.TimeId | yes | single |
| Queries.'Start Date' | Calendar.Date | yes | single |
| 'Mashup Logs'.GatewayId | Gateways.GatewayId | yes | single |
| 'Queries - Datasources'.QueryTrackingId | Queries.QueryTrackingId | yes | both |
| Requests.Date | Calendar.Date | no | single |
| Logs.RootActivityId | Requests.RequestId | yes | single |
| Queries.RequestId | Requests.RequestId | yes | both |
| 'System Counters'.GatewayId | Gateways.GatewayId | yes | single |
| 'Ingestion Uploads'.ServerId | Servers.ServerId | yes | single |
| 'Agent Runs'.ServerId | Servers.ServerId | yes | single |
| 'Ingestion Issues'.ServerId | Servers.ServerId | yes | single |
| 'Ingestion Uploads'.GatewayId | Gateways.GatewayId | yes | single |
| 'Ingestion Issues'.GatewayId | Gateways.GatewayId | yes | single |
| 'Ingestion Uploads'.'Upload Date' | Calendar.Date | yes | single |
| 'Agent Runs'.'Run Date' | Calendar.Date | yes | single |
| 'Processing Runs'.'Run Date' | Calendar.Date | yes | single |
| 'Ingestion Issues'.'Detected Date' | Calendar.Date | yes | single |

`Param - Counters Axis` and `Param - Counters Measure` are calculated field-parameter tables (no Lakehouse table).

## Bronze (`bronze`)

Raw records exactly as uploaded by the agents, with ingestion metadata. Append-only, deduplicated by record id.

### `bronze.gateway_records`

Raw gateway log records exactly as uploaded, with ingestion metadata. CSV rows also keep a header-keyed JSON object so later gateway versions with new columns never break ingestion.

| Property | Value |
|---|---|
| Grain | One record of one uploaded segment |
| Key | `record_id` |
| Partitioned by | `ingest_date` |
| Deduplication | Segments already in ops.segment_registry are skipped; insert-only MERGE on record_id |
| Retention | retention.bronzeDays (default 30) |
| Source | landing/raw segments listed in landing/manifests |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_id` | string | no |  | SHA-256(segment_id, record index) |
| `record_key` | string | no |  | SHA-256(log_type, gateway_id, [snapshot fingerprint], raw record) |
| `segment_id` | string | no |  | Segment identifier from the manifest |
| `record_index` | bigint | no |  | Position of the record inside the segment |
| `record_offset` | bigint | yes |  | Absolute byte offset in the source file (null for UTF-16 files) |
| `log_type` | string | no |  | Log type |
| `record_format` | string | no |  | trace \| jsonl \| csv \| profile \| json |
| `record_text` | string | yes |  | Raw record text (truncated to bronze.maxRecordChars) |
| `record_fields_json` | string | yes |  | CSV only: JSON object keyed by the file header |
| `record_truncated` | boolean | yes |  | True when record_text was truncated |
| `parse_status` | string | no |  | ok \| malformed |
| `parse_error` | string | yes |  | Reason when malformed |
| `environment` | string | yes |  | Environment |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `gateway_id` | string | yes |  | Gateway node id resolved by the agent |
| `server_name` | string | yes |  | Server host name |
| `server_id` | string | yes |  | Server id |
| `agent_instance_id` | string | yes |  | Agent installation id |
| `agent_version` | string | yes |  | Agent version |
| `source_name` | string | yes |  | Agent source name |
| `source_file_name` | string | yes |  | Original file name |
| `source_file_path` | string | yes |  | Original file path on the gateway server |
| `source_fingerprint` | string | yes |  | SHA-256 of the first KiB (incremental) or content (snapshot) |
| `source_last_write_utc` | timestamp | yes |  | Source file last write time (UTC) |
| `raw_path` | string | yes |  | Path of the segment relative to the landing root |
| `manifest_run_id` | string | yes |  | Agent run id of the manifest |
| `uploaded_utc` | timestamp | yes |  | Upload time reported by the agent (UTC) |
| `ingest_batch_id` | string | no |  | Bronze batch id |
| `ingested_utc` | timestamp | no |  | Bronze ingestion time (UTC) |
| `ingest_date` | date | no |  | Partition: ingestion date (UTC) |

## Silver (`silver`)

Parsed, typed and normalized records per log family, redacted, deduplicated by content key.

### `silver.gateway_logs`

Parsed gateway trace records (GatewayInfo, GatewayErrors, GatewayNetwork).

| Property | Value |
|---|---|
| Grain | One trace record |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays (default 400) |
| Source | bronze.gateway_records where log_type in gateway-info/errors/network |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `instance` | string | yes |  | Trace source, e.g. DM.EnterpriseGateway |
| `level` | string | yes |  | Information, Error, Warning, Verbose |
| `event_utc` | timestamp | yes |  | Event timestamp (UTC, 1 µs precision) |
| `activity_id` | string | yes |  | Activity id |
| `root_activity_id` | string | yes |  | Root activity (request) id |
| `activity_type` | string | yes |  | Activity type code |
| `client_activity_id` | string | yes |  | Client activity id |
| `root_gateway_client_pipeline_id` | string | yes |  | Root gateway client pipeline id (SourceId) |
| `current_gateway_client_pipeline_id` | string | yes |  | Current gateway client pipeline id (HelperId) |
| `hash` | string | yes |  | Event hash |
| `event_type` | string | yes |  | Event type, e.g. [DM.GatewayCore] |
| `event_text` | string | yes |  | Full event text (redaction rules applied) |
| `event_text_length` | int | yes |  | Length of the event text |
| `record_offset` | bigint | yes |  | Byte offset in the source file |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |
| `event_date` | date | yes |  | Event date (UTC) |
| `event_month` | int | no |  | Partition: event month yyyyMM (UTC) |

### `silver.artifact_traces`

Evaluation trace contexts (dataset/workspace ids per request) extracted from GatewayInfo records.

| Property | Value |
|---|---|
| Grain | One EvaluationTraceContext record |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | silver.gateway_logs (gateway-info) |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Key of the source trace record |
| `record_id` | string | yes |  | Bronze record id |
| `segment_id` | string | yes |  | Segment id |
| `gateway_id` | string | yes |  | Gateway node id |
| `environment` | string | yes |  | Environment |
| `server_id` | string | yes |  | Server id |
| `source_file_name` | string | yes |  | Log file name |
| `event_utc` | timestamp | yes |  | Event timestamp (UTC) |
| `root_activity_id` | string | yes |  | Root activity id |
| `current_activity_id` | string | yes |  | Current activity id |
| `dataset_id` | string | yes |  | Semantic model (dataset) id |
| `query_type` | string | yes |  | Query type |
| `sku` | string | yes |  | Capacity SKU |
| `workspace_id` | string | yes |  | Workspace id |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |
| `event_date` | date | yes |  | Event date (UTC) |
| `event_month` | int | no |  | Partition: event month yyyyMM (UTC) |

### `silver.query_starts`

Query Start Report rows.

| Property | Value |
|---|---|
| Grain | One query start |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type = query-start-report |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `request_id` | string | yes |  | Request id |
| `query_tracking_id` | string | yes |  | Query tracking id |
| `query_start_utc` | timestamp | yes |  | QueryExecutionStartTimeUTC |
| `query_type` | string | yes |  | Refresh, DirectQuery, ... |
| `data_source` | string | yes |  | DataSource (JSON) |
| `query_text` | string | yes |  | Decoded query text (redaction rules applied) |
| `query_text_length` | int | yes |  | Length of the decoded query text |
| `evaluation_context` | string | yes |  | EvaluationContext (newer gateways) |
| `extra_columns` | string | yes |  | Unknown columns (schema drift) as JSON |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |
| `event_date` | date | yes |  | Event date (UTC) |
| `event_month` | int | no |  | Partition: event month yyyyMM (UTC) |

### `silver.query_executions`

Query Execution Report rows.

| Property | Value |
|---|---|
| Grain | One query execution |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type = query-execution-report |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `request_id` | string | yes |  | Request id |
| `query_tracking_id` | string | yes |  | Query tracking id |
| `data_source` | string | yes |  | DataSource (JSON) |
| `query_type` | string | yes |  | Query type |
| `query_execution_end_utc` | timestamp | yes |  | QueryExecutionEndTimeUTC |
| `query_execution_duration_ms` | bigint | yes |  | QueryExecutionDuration(ms) |
| `data_reading_and_serialization_duration_ms` | bigint | yes |  | DataReadingAndSerializationDuration(ms) |
| `spooling_disk_writing_duration_ms` | bigint | yes |  | SpoolingDiskWritingDuration(ms) |
| `spooling_disk_reading_duration_ms` | bigint | yes |  | SpoolingDiskReadingDuration(ms) |
| `spooling_total_data_size_bytes` | bigint | yes |  | SpoolingTotalDataSize(byte) |
| `data_processing_end_utc` | timestamp | yes |  | DataProcessingEndTimeUTC |
| `data_processing_duration_ms` | bigint | yes |  | DataProcessingDuration(ms) |
| `success` | string | yes |  | Y / N |
| `error_message` | string | yes |  | Error message (redaction rules applied) |
| `extra_columns` | string | yes |  | Unknown columns (schema drift) as JSON |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |
| `event_date` | date | yes |  | Event date (UTC) |
| `event_month` | int | no |  | Partition: event month yyyyMM (UTC) |

### `silver.query_aggregations`

Query Execution Aggregation Report rows (not used by the original model; available for SQL analysis).

| Property | Value |
|---|---|
| Grain | Aggregation window × data source × success × query type |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type = query-execution-aggregation-report |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `aggregation_start_utc` | timestamp | yes |  | AggregationStartTimeUTC |
| `aggregation_end_utc` | timestamp | yes |  | AggregationEndTimeUTC |
| `data_source` | string | yes |  | DataSource (JSON) |
| `success` | string | yes |  | Success |
| `average_query_execution_duration_ms` | double | yes |  | AverageQueryExecutionDuration(ms) |
| `max_query_execution_duration_ms` | double | yes |  | MaxQueryExecutionDuration(ms) |
| `min_query_execution_duration_ms` | double | yes |  | MinQueryExecutionDuration(ms) |
| `query_type` | string | yes |  | QueryType |
| `average_data_processing_duration_ms` | double | yes |  | AverageDataProcessingDuration(ms) |
| `max_data_processing_duration_ms` | double | yes |  | MaxDataProcessingDuration(ms) |
| `min_data_processing_duration_ms` | double | yes |  | MinDataProcessingDuration(ms) |
| `query_count` | bigint | yes |  | Count |
| `extra_columns` | string | yes |  | Unknown columns (schema drift) as JSON |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |
| `event_date` | date | yes |  | Event date (UTC) |
| `event_month` | int | no |  | Partition: event month yyyyMM (UTC) |

### `silver.system_counters`

System Counter Aggregation Report rows.

| Property | Value |
|---|---|
| Grain | Counter × aggregation window |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type = system-counter-aggregation-report |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `aggregation_start_utc` | timestamp | yes |  | AggregationStartTimeUTC |
| `aggregation_end_utc` | timestamp | yes |  | AggregationEndTimeUTC |
| `counter_name` | string | yes |  | SystemCPUPercent, SystemMEMUsedPercent, GatewayCPUPercent, GatewayMEMKb, ... |
| `max_value` | double | yes |  | Max |
| `min_value` | double | yes |  | Min |
| `average_value` | double | yes |  | Average |
| `extra_columns` | string | yes |  | Unknown columns (schema drift) as JSON |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |
| `event_date` | date | yes |  | Event date (UTC) |
| `event_month` | int | no |  | Partition: event month yyyyMM (UTC) |

### `silver.mashup_logs`

Mashup engine log events (JSON lines).

| Property | Value |
|---|---|
| Grain | One mashup event |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type = mashup |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `start_utc` | timestamp | yes |  | Start |
| `action` | string | yes |  | Action |
| `action_group` | string | yes |  | Action before the first '/' |
| `action_detail` | string | yes |  | Action after the first '/' |
| `product_version` | string | yes |  | ProductVersion |
| `activity_id` | string | yes |  | ActivityId |
| `process` | string | yes |  | Process |
| `pid` | bigint | yes |  | Pid |
| `duration_ms` | double | yes |  | Duration in milliseconds |
| `resource_kind` | string | yes |  | ResourceKind |
| `resource_path` | string | yes |  | ResourcePath |
| `row_count` | bigint | yes |  | RowCount |
| `connection_timeout` | bigint | yes |  | ConnectionTimeout |
| `exception` | string | yes |  | Exception (redaction rules applied) |
| `identity` | string | yes |  | identity ('Default' when missing) |
| `container_id` | bigint | yes |  | containerID |
| `pool_count` | bigint | yes |  | poolCount |
| `running_count` | bigint | yes |  | runningCount |
| `pending_count` | bigint | yes |  | pendingCount |
| `non_fatal_error` | string | yes |  | NonFatalError |
| `command_text` | string | yes |  | CommandText (redaction rules applied) |
| `command_timeout` | bigint | yes |  | CommandTimeout |
| `engine_edition` | string | yes |  | EngineEdition |
| `firewall_group` | string | yes |  | FirewallGroup |
| `error_yn` | string | yes |  | 'Y' when Exception is present |
| `extra_columns` | string | yes |  | Unknown fields (schema drift) as JSON |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |
| `event_date` | date | yes |  | Event date (UTC) |
| `event_month` | int | no |  | Partition: event month yyyyMM (UTC) |

### `silver.mashup_container_profiles`

Mashup container pool settings from MashupContainerProfiles.log snapshots.

| Property | Value |
|---|---|
| Grain | Snapshot × pool type |
| Key | `record_key` |
| Deduplication | Insert-only MERGE on record_key (includes the snapshot hash) |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type = mashup-container-profiles |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `snapshot_key` | string | yes |  | Content hash of the snapshot file |
| `snapshot_utc` | timestamp | yes |  | Source last write time (or upload time) |
| `pool_type_id` | bigint | yes |  | MashupContainerPoolType |
| `pool_type` | string | yes |  | Pool type name |
| `container_max_count` | bigint | yes |  | ContainerMaxCount |
| `container_max_working_set_in_mb` | bigint | yes |  | ContainerMaxWorkingSetInMB |
| `container_max_commit_in_mb` | bigint | yes |  | ContainerMaxCommitInMB |
| `container_time_to_live_in_minute` | bigint | yes |  | ContainerTimeToLiveInMinute |
| `cache_time_to_live_in_minute` | bigint | yes |  | CacheTimeToLiveInMinute |
| `session_time_to_live_in_minute` | bigint | yes |  | SessionTimeToLiveInMinute |
| `enable_caching` | boolean | yes |  | EnableCaching |
| `metadata_cache_time_to_live_in_minute` | bigint | yes |  | MetadataCacheTimeToLiveInMinute |
| `metadata_cache_max_size_in_mb` | bigint | yes |  | MetadataCacheMaxSizeInMB |
| `data_cache_time_to_live_in_minute` | bigint | yes |  | DataCacheTimeToLiveInMinute |
| `data_cache_max_size_in_mb` | bigint | yes |  | DataCacheMaxSizeInMB |
| `extra_columns` | string | yes |  | Unknown fields as JSON |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |

### `silver.gateway_metadata`

Gateway/server metadata snapshots from the agent (agent-metadata) and exported GatewayProperties.txt.

| Property | Value |
|---|---|
| Grain | Metadata snapshot |
| Key | `record_key` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type in agent-metadata, gateway-properties |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `snapshot_key` | string | yes |  | Content hash of the snapshot |
| `snapshot_utc` | timestamp | yes |  | Collection time |
| `metadata_source` | string | yes |  | agent-metadata \| gateway-properties |
| `gateway_name` | string | yes |  | Gateway name |
| `cluster_name` | string | yes |  | Cluster name |
| `version` | string | yes |  | Gateway version |
| `service_status` | string | yes |  | Gateway Windows service status |
| `server_fqdn` | string | yes |  | Server FQDN |
| `metadata_server_id` | string | yes |  | Server id reported in the document |
| `number_of_cores` | bigint | yes |  | Logical processors |
| `memory_mb` | bigint | yes |  | Total memory (MB) reported by the agent |
| `memory_reported` | bigint | yes |  | SystemTotalMemory as reported (unit as in the source) |
| `os_architecture` | string | yes |  | OS architecture |
| `os_version` | string | yes |  | OS version |
| `time_zone_id` | string | yes |  | Windows time zone id |
| `utc_offset_minutes` | int | yes |  | UTC offset at collection time |
| `metadata_agent_version` | string | yes |  | Agent version that produced the snapshot |
| `collected_utc` | timestamp | yes |  | collectedUtc |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |

### `silver.gateway_cluster_members`

Cluster membership from exported GatewayClusters.txt files.

| Property | Value |
|---|---|
| Grain | Snapshot × member gateway |
| Key | `record_key` |
| Deduplication | Insert-only MERGE on record_key |
| Retention | retention.silverDays |
| Source | bronze.gateway_records where log_type = gateway-clusters |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Content-addressed key: SHA-256(log_type, gateway_id, raw record) |
| `record_id` | string | yes |  | Bronze record id: SHA-256(segment_id, record index) |
| `segment_id` | string | yes |  | Uploaded segment that contained the record |
| `gateway_id` | string | yes |  | Gateway node object id (lower-case GUID) |
| `cluster_id` | string | yes |  | Gateway cluster id |
| `environment` | string | yes |  | Environment label configured on the agent |
| `server_id` | string | yes |  | Truncated SHA-256 of the server MachineGuid |
| `server_name` | string | yes |  | Server host name |
| `log_type` | string | yes |  | Log type (see architecture §3.2) |
| `source_file_name` | string | yes |  | Original gateway log file name |
| `snapshot_key` | string | yes |  | Content hash of the snapshot |
| `snapshot_utc` | timestamp | yes |  | Snapshot time |
| `cluster_name` | string | yes |  | Cluster name |
| `gateway_status` | string | yes |  | Member status |
| `ingest_batch_id` | string | yes |  | Bronze batch that ingested the record |
| `ingested_utc` | timestamp | yes |  | Bronze ingestion time (UTC) |
| `processed_utc` | timestamp | yes |  | Silver processing time (UTC) |

## Gold (`gold`)

Star schema read by the Direct Lake semantic model (original pbigtwmonitor tables + ingestion health).

### `gold.calendar`

Date dimension (UTC dates).

| Property | Value |
|---|---|
| Grain | Day |
| Key | `date` |
| Deduplication | Rebuilt every run |
| Retention | 1-Jan previous year → 31-Dec current year, extended to fact dates |
| Source | Generated |
| Model table | Calendar |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `date` | date | no | Date |  |
| `date_id` | int | yes | DateId |  |
| `day` | int | yes | Day |  |
| `day_relative` | int | yes | Day (Relative) |  |
| `has_logs` | boolean | yes | Has Logs? |  |
| `month_short` | string | yes | Month |  |
| `month_number` | int | yes | Month (#) |  |
| `month_long` | string | yes | Month (Long) |  |
| `month_relative` | int | yes | Month (Relative) |  |
| `month_year` | string | yes | Month (Year) |  |
| `month_year_id` | int | yes | MonthYearId |  |
| `quarter` | int | yes | Quarter |  |
| `quarter_year` | string | yes | Quarter (Year) |  |
| `quarter_year_id` | int | yes | QuarterYearId |  |
| `semester` | int | yes | Semester |  |
| `semester_year` | string | yes | Semester (Year) |  |
| `semester_year_id` | int | yes | SemesterYearId |  |
| `week` | int | yes | Week |  |
| `week_relative` | int | yes | Week (Relative) |  |
| `week_year` | string | yes | Week (Year) |  |
| `week_day` | string | yes | Week Day |  |
| `week_day_number` | int | yes | Week Day (#) |  |
| `week_end_date` | date | yes | Week End Date |  |
| `week_start_date` | date | yes | Week Start Date |  |
| `week_year_id` | int | yes | WeekYearId |  |
| `work_day` | string | yes | Work Day |  |
| `year` | int | yes | Year |  |
| `year_relative` | int | yes | Year (Relative) |  |

### `gold.time_of_day`

Minute-grain time dimension (UTC).

| Property | Value |
|---|---|
| Grain | Minute |
| Key | `time_id` |
| Deduplication | Rebuilt every run |
| Retention | Static (1,440 rows) |
| Source | Generated |
| Model table | Time |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `time_id` | int | no | TimeId |  |
| `hour` | timestamp | yes | Hour |  |
| `hour_number` | int | yes | Hour (#) |  |
| `minute` | timestamp | yes | Minute |  |
| `minute_number` | int | yes | Minute (#) |  |
| `quarter_hour` | timestamp | yes | Quarter Hour |  |
| `half_hour` | timestamp | yes | Half Hour |  |
| `day_period` | string | yes | Day Period |  |
| `day_period_start` | timestamp | yes | Day Period Start |  |
| `day_period_end` | timestamp | yes | Day Period End |  |

### `gold.gateways`

Gateway node dimension (one row per GatewayObjectId ever seen).

| Property | Value |
|---|---|
| Grain | Gateway node |
| Key | `gateway_id` |
| Deduplication | Rebuilt every run; manual overrides > GatewayClusters > metadata > defaults |
| Retention | All gateways seen in Silver or registries |
| Source | silver.gateway_metadata, silver.gateway_cluster_members, gateway-overrides.json, facts, ops registries |
| Model table | Gateways |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `gateway_id` | string | no | GatewayId | Gateway node object id |
| `gateway_name` | string | yes | Gateway | Gateway name (falls back to the id) |
| `cluster_name` | string | yes | Cluster | Cluster name (falls back to the gateway name) |
| `server_name` | string | yes | Server | Latest server hosting the gateway |
| `version` | string | yes | Version | Gateway version |
| `number_of_cores` | bigint | yes | NumberOfCores | Logical processors of the server |
| `memory` | bigint | yes | Memory | Total memory (MB when reported by the agent) |
| `os_architecture` | string | yes | OSArchitecture | OS architecture |
| `os_version` | string | yes | OSVersion | OS version |
| `cluster_id` | string | yes | Cluster Id | Gateway cluster id |
| `environment` | string | yes | Environment | Environment label |
| `server_id` | string | yes | Server Id | Server id |
| `installation_id` | string | yes | Installation Id | SHA-256(server_id, gateway_id) truncated |
| `agent_version` | string | yes | Agent Version | Latest collection agent version |
| `first_seen_utc` | timestamp | yes | First Seen (UTC) | First event or upload |
| `last_seen_utc` | timestamp | yes | Last Seen (UTC) | Last event or upload |
| `status` | string | yes | Status | Active / Inactive (no data for gold.inactiveAfterDays) |

### `gold.logs`

Gateway log records loaded into the model (gold.logTypes).

| Property | Value |
|---|---|
| Grain | Log record |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Recomputed per affected month from silver.gateway_logs |
| Retention | gold.windowDays (default 180) |
| Source | silver.gateway_logs |
| Model table | Logs |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Record key |
| `activity_id` | string | yes | ActivityId |  |
| `activity_type` | string | yes | ActivityType |  |
| `client_activity_id` | string | yes | ClientActivityId |  |
| `current_gateway_client_pipeline_id` | string | yes | CurrentGatewayClientPipelineId |  |
| `date` | date | yes | Date |  |
| `date_time` | timestamp | yes | DateTime | Event time truncated to the minute (UTC) |
| `event_text` | string | yes | EventText | Event text truncated to gold.maxLogTextLength |
| `event_type` | string | yes | EventType |  |
| `gateway_id` | string | yes | GatewayId |  |
| `hash` | string | yes | Hash |  |
| `hour` | timestamp | yes | Hour | Time of day (UTC) |
| `instance` | string | yes | Instance |  |
| `level` | string | yes | Level |  |
| `log_file_name` | string | yes | LogFileName |  |
| `root_activity_id` | string | yes | RootActivityId |  |
| `root_gateway_client_pipeline_id` | string | yes | RootGatewayClientPipelineId |  |
| `time_id` | int | yes | TimeId |  |
| `log_type` | string | yes | Log Type | gateway-info, gateway-errors, gateway-network |
| `event_utc` | timestamp | yes |  | Full-precision event time (UTC) |
| `server_id` | string | yes |  | Server id |
| `event_month` | int | no |  | Partition: event month yyyyMM |

### `gold.logs_artifact_trace`

Dataset/workspace ids per request extracted from evaluation traces.

| Property | Value |
|---|---|
| Grain | (gateway, root activity, dataset) |
| Key | `gateway_id`, `root_activity_id`, `dataset_id` |
| Deduplication | Distinct (gateway_id, root_activity_id, dataset_id), rebuilt every run |
| Retention | gold.windowDays |
| Source | silver.artifact_traces |
| Model table | LogsArtifactTrace |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `current_activity_id` | string | yes | CurrentActivityId |  |
| `dataset_id` | string | yes | DatasetId |  |
| `gateway_id` | string | yes | GatewayId |  |
| `log_file_name` | string | yes | LogFileName |  |
| `query_type` | string | yes | QueryType |  |
| `root_activity_id` | string | yes | RootActivityId |  |
| `sku` | string | yes | SKU |  |
| `workspace_id` | string | yes | WorkspaceId |  |

### `gold.queries`

Gateway queries (start ⟕ execution).

| Property | Value |
|---|---|
| Grain | Query (QueryTrackingId) |
| Key | `query_tracking_id` |
| Partitioned by | `event_month` |
| Deduplication | One row per query_tracking_id: latest start attempt, latest matching execution |
| Retention | gold.windowDays |
| Source | silver.query_starts, silver.query_executions, silver.artifact_traces |
| Model table | Queries |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `data_processing_duration_ms` | bigint | yes | DataProcessingDuration(ms) |  |
| `data_reading_and_serialization_duration_ms` | bigint | yes | DataReadingAndSerializationDuration(ms) |  |
| `dataset_id` | string | yes | DatasetId |  |
| `datasources` | string | yes | Datasources |  |
| `date_time` | timestamp | yes | DateTime |  |
| `end_date` | date | yes | End Date |  |
| `end_time` | timestamp | yes | End Time |  |
| `error_message` | string | yes | ErrorMessage |  |
| `file_name` | string | yes | Filename |  |
| `gateway_id` | string | yes | GatewayId |  |
| `query_execution_duration_ms` | bigint | yes | QueryExecutionDuration(ms) |  |
| `query_text` | string | yes | QueryText |  |
| `query_tracking_id` | string | no | QueryTrackingId |  |
| `query_type` | string | yes | QueryType |  |
| `request_id` | string | yes | RequestId |  |
| `spooling_disk_reading_duration_ms` | bigint | yes | SpoolingDiskReadingDuration(ms) |  |
| `spooling_disk_writing_duration_ms` | bigint | yes | SpoolingDiskWritingDuration(ms) |  |
| `spooling_total_data_size_bytes` | bigint | yes | SpoolingTotalDataSize(byte) |  |
| `start_date` | date | yes | Start Date |  |
| `start_time` | timestamp | yes | Start Time |  |
| `success` | string | yes | Success |  |
| `time_id` | int | yes | TimeId |  |
| `total_query_execution_ms` | bigint | yes | TotalQueryExecution(ms) |  |
| `workspace_id` | string | yes | WorkspaceId |  |
| `evaluation_context` | string | yes | EvaluationContext | EvaluationContext column of newer gateways |
| `query_start_utc` | timestamp | yes |  | Full-precision start (UTC) |
| `query_end_utc` | timestamp | yes |  | Full-precision end: DataProcessingEndTimeUTC ?? QueryExecutionEndTimeUTC |
| `server_id` | string | yes |  | Server id |
| `event_month` | int | no |  | Partition: start month yyyyMM |

### `gold.query_datasources`

Data sources of each query.

| Property | Value |
|---|---|
| Grain | (query, data source) |
| Key | `query_tracking_id`, `datasource_kind`, `datasource_path` |
| Partitioned by | `event_month` |
| Deduplication | Distinct per query |
| Retention | gold.windowDays |
| Source | silver.query_starts |
| Model table | Queries - Datasources |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `query_tracking_id` | string | yes | QueryTrackingId |  |
| `datasource_kind` | string | yes | DataSource - Kind |  |
| `datasource_path` | string | yes | DataSource - Path |  |
| `event_month` | int | no |  | Partition: query start month |

### `gold.requests`

Requests (root activities) derived from logs and queries.

| Property | Value |
|---|---|
| Grain | Request |
| Key | `request_id` |
| Partitioned by | `event_month` |
| Deduplication | Recomputed for request ids touched by affected months (MERGE) |
| Retention | gold.windowDays |
| Source | gold.logs, gold.queries |
| Model table | Requests |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `request_id` | string | no | RequestId |  |
| `request_start` | timestamp | yes | Start |  |
| `request_end` | timestamp | yes | End |  |
| `duration_s` | bigint | yes | Duration |  |
| `duration_queries_s` | bigint | yes | DurationQueries |  |
| `date` | date | yes | Date |  |
| `has_queries` | string | yes | Has Queries (Y/N) |  |
| `event_month` | int | no |  | Partition: start month |

### `gold.mashup_logs`

Mashup engine events.

| Property | Value |
|---|---|
| Grain | Mashup event |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Recomputed per affected month |
| Retention | gold.windowDays |
| Source | silver.mashup_logs |
| Model table | Mashup Logs |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Record key |
| `action` | string | yes | Action |  |
| `action_detail` | string | yes | Action Detail |  |
| `action_group` | string | yes | Action Group |  |
| `activity_id` | string | yes | ActivityId |  |
| `command_text` | string | yes | CommandText |  |
| `command_timeout` | bigint | yes | CommandTimeout |  |
| `connection_timeout` | bigint | yes | ConnectionTimeout |  |
| `container_id` | bigint | yes | ContainerID |  |
| `date` | date | yes | Date |  |
| `date_time` | timestamp | yes | DateTime |  |
| `duration_ms` | double | yes | Duration (ms) |  |
| `engine_edition` | string | yes | EngineEdition |  |
| `error_yn` | string | yes | Error (Y/N) |  |
| `exception` | string | yes | Exception |  |
| `file_name` | string | yes | Filename |  |
| `firewall_group` | string | yes | FirewallGroup |  |
| `gateway_id` | string | yes | GatewayId |  |
| `identity` | string | yes | Identity |  |
| `non_fatal_error` | string | yes | NonFatalError |  |
| `pid` | bigint | yes | Pid |  |
| `process` | string | yes | Process |  |
| `product_version` | string | yes | ProductVersion |  |
| `resource_kind` | string | yes | ResourceKind |  |
| `resource_path` | string | yes | ResourcePath |  |
| `row_count` | bigint | yes | RowCount |  |
| `time_of_day` | timestamp | yes | Time |  |
| `time_id` | int | yes | TimeId |  |
| `pending_count` | bigint | yes | pendingCount |  |
| `pool_count` | bigint | yes | poolCount |  |
| `running_count` | bigint | yes | runningCount |  |
| `server_id` | string | yes |  | Server id |
| `event_month` | int | no |  | Partition: event month |

### `gold.mashup_container_profile`

Latest mashup container profile per gateway and pool type.

| Property | Value |
|---|---|
| Grain | Gateway × pool type |
| Key | `gateway_id`, `mashup_container_pool_type_id` |
| Deduplication | Latest snapshot per gateway |
| Retention | Latest only |
| Source | silver.mashup_container_profiles |
| Model table | Mashup Container Profile |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `cache_time_to_live_in_minute` | bigint | yes | CacheTimeToLiveInMinute |  |
| `container_max_commit_in_mb` | bigint | yes | ContainerMaxCommitInMB |  |
| `container_max_count` | bigint | yes | ContainerMaxCount |  |
| `container_max_working_set_in_mb` | bigint | yes | ContainerMaxWorkingSetInMB |  |
| `container_time_to_live_in_minute` | bigint | yes | ContainerTimeToLiveInMinute |  |
| `data_cache_max_size_in_mb` | bigint | yes | DataCacheMaxSizeInMB |  |
| `data_cache_time_to_live_in_minute` | bigint | yes | DataCacheTimeToLiveInMinute |  |
| `enable_caching` | boolean | yes | EnableCaching |  |
| `gateway_id` | string | yes | GatewayId |  |
| `mashup_container_pool_type` | string | yes | MashupContainerPoolType |  |
| `mashup_container_pool_type_id` | bigint | yes | MashupContainerPoolTypeId |  |
| `metadata_cache_max_size_in_mb` | bigint | yes | MetadataCacheMaxSizeInMB |  |
| `metadata_cache_time_to_live_in_minute` | bigint | yes | MetadataCacheTimeToLiveInMinute |  |
| `session_time_to_live_in_minute` | bigint | yes | SessionTimeToLiveInMinute |  |
| `snapshot_utc` | timestamp | yes |  | Snapshot time |

### `gold.system_counters`

Gateway performance counters (5-minute aggregation windows by default).

| Property | Value |
|---|---|
| Grain | Counter × window |
| Key | `record_key` |
| Partitioned by | `event_month` |
| Deduplication | Recomputed per affected month |
| Retention | gold.windowDays |
| Source | silver.system_counters |
| Model table | System Counters |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_key` | string | no |  | Record key |
| `aggregation_end_time_utc` | timestamp | yes | AggregationEndTimeUTC |  |
| `aggregation_start_time_utc` | timestamp | yes | AggregationStartTimeUTC |  |
| `average_value` | double | yes | Average |  |
| `counter_name` | string | yes | CounterName |  |
| `date` | date | yes | Date |  |
| `file_name` | string | yes | Filename |  |
| `gateway_id` | string | yes | GatewayId |  |
| `max_value` | double | yes | Max |  |
| `min_value` | double | yes | Min |  |
| `tme_id` | int | yes | TmeId |  |
| `server_id` | string | yes |  | Server id |
| `event_month` | int | no |  | Partition: window end month |

### `gold.ingestion_servers`

Collection agents / servers with their latest status (new ingestion metric).

| Property | Value |
|---|---|
| Grain | Server |
| Key | `server_id` |
| Deduplication | Rebuilt every run |
| Retention | Servers with a run in ops.agent_runs |
| Source | ops.agent_runs, ops.segment_registry, silver.gateway_metadata |
| Model table | Servers |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `server_id` | string | no | ServerId |  |
| `server_name` | string | yes | Server |  |
| `server_fqdn` | string | yes | Server FQDN |  |
| `environment` | string | yes | Environment |  |
| `cluster_id` | string | yes | Cluster Id |  |
| `cluster_name` | string | yes | Cluster |  |
| `gateway_id` | string | yes | Gateway Id |  |
| `gateway_name` | string | yes | Gateway |  |
| `agent_instance_id` | string | yes | Agent Instance Id |  |
| `agent_version` | string | yes | Agent Version |  |
| `time_zone_id` | string | yes | Time Zone |  |
| `utc_offset_minutes` | int | yes | UTC Offset (min) |  |
| `first_seen_utc` | timestamp | yes | First Seen (UTC) |  |
| `last_run_utc` | timestamp | yes | Last Agent Run (UTC) |  |
| `last_run_status` | string | yes | Last Run Status |  |
| `last_successful_run_utc` | timestamp | yes | Last Successful Run (UTC) |  |
| `last_upload_utc` | timestamp | yes | Last Upload (UTC) |  |
| `last_processed_utc` | timestamp | yes | Last Processed (UTC) |  |
| `last_processed_file` | string | yes | Last Processed File |  |
| `expected_interval_minutes` | int | yes | Expected Interval (min) |  |
| `late_after_minutes` | int | yes | Late After (min) |  |
| `missing_after_minutes` | int | yes | Missing After (min) |  |

### `gold.ingestion_uploads`

Uploaded segments and their processing status (new ingestion metric).

| Property | Value |
|---|---|
| Grain | Uploaded segment |
| Key | `segment_id` |
| Deduplication | Rebuilt every run |
| Retention | gold.ingestionWindowDays (default 30) |
| Source | ops.segment_registry |
| Model table | Ingestion Uploads |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `segment_id` | string | no | Segment Id |  |
| `server_id` | string | yes | ServerId |  |
| `gateway_id` | string | yes | GatewayId |  |
| `environment` | string | yes | Environment |  |
| `cluster_id` | string | yes | Cluster Id |  |
| `log_type` | string | yes | Log Type |  |
| `source_file_name` | string | yes | Source File |  |
| `raw_path` | string | yes | Raw Path |  |
| `byte_count` | bigint | yes | Bytes |  |
| `record_count` | bigint | yes | Records |  |
| `malformed_count` | bigint | yes | Malformed Records |  |
| `source_last_write_utc` | timestamp | yes | Source Last Write (UTC) |  |
| `uploaded_utc` | timestamp | yes | Uploaded (UTC) |  |
| `upload_date` | date | yes | Upload Date |  |
| `processed_utc` | timestamp | yes | Processed (UTC) |  |
| `status` | string | yes | Status |  |
| `attempts` | int | yes | Attempts |  |
| `upload_latency_minutes` | double | yes | Upload Latency (min) |  |
| `processing_latency_minutes` | double | yes | Processing Latency (min) |  |
| `total_latency_minutes` | double | yes | Ingestion Latency (min) |  |
| `manifest_run_id` | string | yes | Agent Run Id |  |
| `error` | string | yes | Error |  |

### `gold.ingestion_agent_runs`

Collection agent runs (heartbeats) (new ingestion metric).

| Property | Value |
|---|---|
| Grain | Agent run |
| Key | `run_id` |
| Deduplication | Rebuilt every run |
| Retention | gold.ingestionWindowDays |
| Source | ops.agent_runs |
| Model table | Agent Runs |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `run_id` | string | no | Run Id |  |
| `server_id` | string | yes | ServerId |  |
| `environment` | string | yes | Environment |  |
| `agent_version` | string | yes | Agent Version |  |
| `agent_instance_id` | string | yes | Agent Instance Id |  |
| `started_utc` | timestamp | yes | Started (UTC) |  |
| `ended_utc` | timestamp | yes | Ended (UTC) |  |
| `run_date` | date | yes | Run Date |  |
| `duration_seconds` | double | yes | Duration (s) |  |
| `status` | string | yes | Status |  |
| `trigger` | string | yes | Trigger |  |
| `auth_mode` | string | yes | Auth Mode |  |
| `files_scanned` | bigint | yes | Files Scanned |  |
| `segments_uploaded` | bigint | yes | Segments Uploaded |  |
| `bytes_uploaded` | bigint | yes | Bytes Uploaded |  |
| `errors` | bigint | yes | Errors |  |
| `warnings` | bigint | yes | Warnings |  |
| `issues_summary` | string | yes | Issues |  |

### `gold.ingestion_processing_runs`

Notebook runs (new ingestion metric).

| Property | Value |
|---|---|
| Grain | Notebook run |
| Key | `run_id` |
| Deduplication | Rebuilt every run |
| Retention | gold.ingestionWindowDays |
| Source | ops.processing_runs |
| Model table | Processing Runs |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `run_id` | string | no | Run Id |  |
| `stage` | string | yes | Stage |  |
| `notebook` | string | yes | Notebook |  |
| `started_utc` | timestamp | yes | Started (UTC) |  |
| `ended_utc` | timestamp | yes | Ended (UTC) |  |
| `run_date` | date | yes | Run Date |  |
| `duration_seconds` | double | yes | Duration (s) |  |
| `status` | string | yes | Status |  |
| `rows_read` | bigint | yes | Rows Read |  |
| `rows_written` | bigint | yes | Rows Written |  |
| `rows_rejected` | bigint | yes | Rows Rejected |  |
| `batch_id` | string | yes | Batch Id |  |
| `error_message` | string | yes | Error |  |

### `gold.ingestion_issues`

Quarantined files, rejected records, missing segments, failures and schema drift (new).

| Property | Value |
|---|---|
| Grain | Issue |
| Key | `issue_id` |
| Deduplication | Rebuilt every run |
| Retention | gold.ingestionWindowDays |
| Source | ops.rejected_records, ops.quarantined_files, ops.segment_registry, ops.agent_runs, ops.processing_runs, ops.schema_drift |
| Model table | Ingestion Issues |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `issue_id` | string | no | Issue Id |  |
| `issue_type` | string | yes | Issue Type |  |
| `severity` | string | yes | Severity |  |
| `detected_utc` | timestamp | yes | Detected (UTC) |  |
| `detected_date` | date | yes | Detected Date |  |
| `server_id` | string | yes | ServerId |  |
| `gateway_id` | string | yes | GatewayId |  |
| `log_type` | string | yes | Log Type |  |
| `object_path` | string | yes | Object |  |
| `reason` | string | yes | Reason |  |
| `details` | string | yes | Details |  |
| `occurrences` | bigint | yes | Occurrences |  |
| `batch_id` | string | yes | Batch Id |  |

## Ops (`ops`)

Operational registries and run logs: manifests, segments, agent and processing runs, rejected and quarantined data, schema drift.

### `ops.manifest_registry`

Manifests seen by the Bronze notebook.

| Property | Value |
|---|---|
| Grain | Manifest file |
| Key | `manifest_path` |
| Deduplication | MERGE on manifest_path |
| Retention | retention.opsDays |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `manifest_path` | string | no |  |  |
| `run_id` | string | yes |  |  |
| `environment` | string | yes |  |  |
| `server_name` | string | yes |  |  |
| `server_id` | string | yes |  |  |
| `agent_instance_id` | string | yes |  |  |
| `agent_version` | string | yes |  |  |
| `created_utc` | timestamp | yes |  |  |
| `segment_count` | bigint | yes |  |  |
| `status` | string | yes |  | Registered \| Invalid |
| `error` | string | yes |  |  |
| `registered_utc` | timestamp | yes |  |  |
| `batch_id` | string | yes |  |  |

### `ops.segment_registry`

Every segment listed in a manifest and its ingestion status (processing checkpoint).

| Property | Value |
|---|---|
| Grain | Segment |
| Key | `segment_id` |
| Deduplication | MERGE on segment_id |
| Retention | retention.opsDays |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `segment_id` | string | no |  |  |
| `manifest_run_id` | string | yes |  |  |
| `manifest_path` | string | yes |  |  |
| `raw_path` | string | yes |  |  |
| `log_type` | string | yes |  |  |
| `record_format` | string | yes |  |  |
| `environment` | string | yes |  |  |
| `cluster_id` | string | yes |  |  |
| `cluster_name` | string | yes |  |  |
| `gateway_id` | string | yes |  |  |
| `gateway_name` | string | yes |  |  |
| `server_name` | string | yes |  |  |
| `server_id` | string | yes |  |  |
| `agent_instance_id` | string | yes |  |  |
| `agent_version` | string | yes |  |  |
| `source_name` | string | yes |  |  |
| `source_file_name` | string | yes |  |  |
| `source_file_path` | string | yes |  |  |
| `source_fingerprint` | string | yes |  |  |
| `source_last_write_utc` | timestamp | yes |  |  |
| `offset_start` | bigint | yes |  |  |
| `offset_end` | bigint | yes |  |  |
| `byte_count` | bigint | yes |  |  |
| `header_bytes` | bigint | yes |  |  |
| `sha256` | string | yes |  |  |
| `upload_mode` | string | yes |  |  |
| `uploaded_utc` | timestamp | yes |  |  |
| `status` | string | yes |  | Pending \| Processed \| Missing \| Quarantined |
| `attempts` | int | yes |  |  |
| `record_count` | bigint | yes |  |  |
| `malformed_count` | bigint | yes |  |  |
| `first_seen_utc` | timestamp | yes |  |  |
| `processed_utc` | timestamp | yes |  |  |
| `batch_id` | string | yes |  |  |
| `error` | string | yes |  |  |

### `ops.agent_runs`

Agent run telemetry documents.

| Property | Value |
|---|---|
| Grain | Agent run |
| Key | `run_id` |
| Deduplication | MERGE on run_id |
| Retention | retention.opsDays |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `run_id` | string | no |  |  |
| `environment` | string | yes |  |  |
| `server_name` | string | yes |  |  |
| `server_id` | string | yes |  |  |
| `server_fqdn` | string | yes |  |  |
| `agent_instance_id` | string | yes |  |  |
| `agent_version` | string | yes |  |  |
| `time_zone_id` | string | yes |  |  |
| `utc_offset_minutes` | int | yes |  |  |
| `started_utc` | timestamp | yes |  |  |
| `ended_utc` | timestamp | yes |  |  |
| `duration_ms` | bigint | yes |  |  |
| `status` | string | yes |  |  |
| `trigger` | string | yes |  |  |
| `auth_mode` | string | yes |  |  |
| `target_type` | string | yes |  |  |
| `config_hash` | string | yes |  |  |
| `powershell_version` | string | yes |  |  |
| `os_version` | string | yes |  |  |
| `sources_scanned` | bigint | yes |  |  |
| `files_scanned` | bigint | yes |  |  |
| `files_changed` | bigint | yes |  |  |
| `segments_uploaded` | bigint | yes |  |  |
| `segments_skipped` | bigint | yes |  |  |
| `bytes_uploaded` | bigint | yes |  |  |
| `errors` | bigint | yes |  |  |
| `warnings` | bigint | yes |  |  |
| `gateways_json` | string | yes |  |  |
| `issues_json` | string | yes |  |  |
| `telemetry_path` | string | yes |  |  |
| `received_utc` | timestamp | yes |  |  |

### `ops.processing_runs`

Notebook run log.

| Property | Value |
|---|---|
| Grain | Notebook run |
| Key | `run_id` |
| Deduplication | MERGE on run_id |
| Retention | retention.opsDays |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `run_id` | string | no |  |  |
| `stage` | string | yes |  |  |
| `notebook` | string | yes |  |  |
| `started_utc` | timestamp | yes |  |  |
| `ended_utc` | timestamp | yes |  |  |
| `status` | string | yes |  |  |
| `rows_read` | bigint | yes |  |  |
| `rows_written` | bigint | yes |  |  |
| `rows_rejected` | bigint | yes |  |  |
| `batch_id` | string | yes |  |  |
| `parameters_json` | string | yes |  |  |
| `details_json` | string | yes |  |  |
| `error_message` | string | yes |  |  |
| `lib_version` | string | yes |  |  |

### `ops.watermarks`

Incremental processing watermarks (processing checkpoints).

| Property | Value |
|---|---|
| Grain | Stage |
| Key | `stage` |
| Deduplication | MERGE on stage |
| Retention | Permanent |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `stage` | string | no |  |  |
| `watermark` | string | yes |  |  |
| `updated_utc` | timestamp | yes |  |  |
| `run_id` | string | yes |  |  |

### `ops.rejected_records`

Records that could not be parsed or validated (raw text preserved).

| Property | Value |
|---|---|
| Grain | Rejected record |
| Key | `record_id` |
| Deduplication | MERGE on record_id |
| Retention | retention.opsDays |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `record_id` | string | no |  |  |
| `record_key` | string | yes |  |  |
| `segment_id` | string | yes |  |  |
| `log_type` | string | yes |  |  |
| `gateway_id` | string | yes |  |  |
| `server_id` | string | yes |  |  |
| `server_name` | string | yes |  |  |
| `stage` | string | yes |  |  |
| `reason` | string | yes |  |  |
| `raw_text` | string | yes |  |  |
| `detected_utc` | timestamp | yes |  |  |
| `batch_id` | string | yes |  |  |

### `ops.quarantined_files`

Files that could not be processed (checksum, binary, invalid manifest, orphan).

| Property | Value |
|---|---|
| Grain | Quarantined file |
| Key | `quarantine_id` |
| Deduplication | MERGE on quarantine_id |
| Retention | retention.opsDays |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `quarantine_id` | string | no |  |  |
| `segment_id` | string | yes |  |  |
| `original_path` | string | yes |  |  |
| `quarantine_path` | string | yes |  |  |
| `reason` | string | yes |  |  |
| `details` | string | yes |  |  |
| `detected_utc` | timestamp | yes |  |  |
| `batch_id` | string | yes |  |  |
| `server_name` | string | yes |  |  |
| `server_id` | string | yes |  |  |
| `gateway_id` | string | yes |  |  |
| `log_type` | string | yes |  |  |

### `ops.schema_drift`

Columns/fields seen in source files that are not part of the known schema.

| Property | Value |
|---|---|
| Grain | Log type × column |
| Key | `log_type`, `column_name` |
| Deduplication | MERGE on (log_type, column_name) |
| Retention | Permanent |

| Column | Type | Nullable | Model column | Description |
|---|---|---|---|---|
| `log_type` | string | no |  |  |
| `column_name` | string | no |  |  |
| `first_seen_utc` | timestamp | yes |  |  |
| `last_seen_utc` | timestamp | yes |  |  |
| `occurrences` | bigint | yes |  |  |
| `sample_value` | string | yes |  |  |
| `first_batch_id` | string | yes |  |  |

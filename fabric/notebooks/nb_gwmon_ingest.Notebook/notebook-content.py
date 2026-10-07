# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# MARKDOWN ********************

# # nb_gwmon_ingest — landing → Bronze → Silver → Gold
# 
# Scheduled by the setup notebook (every 2 hours by default). Each run:
# 
# 1. **Setup** — creates the `bronze`, `silver`, `gold` and `ops` schemas and tables when they are missing or when the
#    table contracts changed, the landing folders and, if absent, `Files/gateway-monitor/config/processing.json`.
# 2. **Bronze** — registers new run telemetry and manifests, reads the listed segments and loads the raw records.
# 3. **Silver** — parses, types, redacts and deduplicates the new Bronze records.
# 4. **Gold** — rebuilds the affected months of the tables read by the Direct Lake semantic model.
# 
# Every stage records its run in `ops.processing_runs`. Re-running the notebook never duplicates data. The parameters
# below are only needed for backfills and rebuilds (see docs/configuration.md).

# PARAMETERS CELL ********************

# Bronze: days of manifests and telemetry to scan (0 = processing.json landing.manifestLookbackDays)
lookback_days = 0
# Bronze: re-ingest segments uploaded between these dates (YYYY-MM-DD); raw files must still exist
reprocess_from = ""
reprocess_to = ""
# Bronze: maximum manifests per run (0 = processing.json landing.maxManifestsPerRun)
max_manifests = 0
# Silver: reprocess Bronze batches after this ingest_batch_id ("" = continue from the watermark, "0" = everything)
rebuild_from_batch = ""
# Gold: recompute every Gold table of the window instead of the changed months only
rebuild_gold = False
# Gold: reframe the semantic model at the end (also processing.json semanticModel.reframeAfterGold)
reframe_semantic_model = False
semantic_model_name = ""

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark",
# META   "tags": ["parameters"]
# META }

# CELL ********************

%run nb_gwmon_lib

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# ## 1. Setup — schemas, tables, folders and default configuration

# CELL ********************

configure_spark("silver")
cfg = load_config()

# Tables are only checked when the contracts changed or a table is missing (see ensure_all_tables_if_needed).
added_columns = ensure_all_tables_if_needed()
tables_evolved = {table: columns for table, columns in (added_columns or {}).items() if columns}
if added_columns is not None:
    print(f"[gwmon] tables ensured: {len(added_columns)}; evolved: {tables_evolved}")

landing_root = cfg["landing"]["root"]
folder_warnings = []
for folder in (f"{landing_root}/raw", f"{landing_root}/manifests", f"{landing_root}/telemetry",
               f"{landing_root}/_staging", QUARANTINE_ROOT, f"{FILES_ROOT}/config"):
    try:
        nbutils().fs.mkdirs(folder)
    except Exception as exc:
        folder_warnings.append(f"{folder}: {exc}")
        print(f"[gwmon] WARNING could not create {folder}: {exc}")

config_file = mount_path(CONFIG_PATH)
config_written = False
if not os.path.exists(config_file):
    os.makedirs(os.path.dirname(config_file), exist_ok=True)
    with open(config_file, "w", encoding="utf-8") as handle:
        json.dump(DEFAULT_CONFIG, handle, indent=2)
    config_written = True

if added_columns is not None or config_written or folder_warnings:
    with ProcessingRun("setup", "nb_gwmon_ingest") as run:
        run.details = {
            "tables": sorted((added_columns or {}).keys()),
            "evolved": tables_evolved,
            "folder_warnings": folder_warnings,
            "default_config_written": config_written,
            "lib_version": GWMON_LIB_VERSION,
        }
        setup_summary = run.summary()
else:
    setup_summary = {"stage": "setup", "status": "Skipped", "details": {"reason": "tables up to date"}}

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# ## 2. Bronze — landing to Bronze
# 
# 1. Registers new **run telemetry** documents in `ops.agent_runs`.
# 2. Registers new **manifests** (`ops.manifest_registry`) and their segments (`ops.segment_registry`, status `Pending`).
#    Invalid manifests are quarantined.
# 3. Reads every `Pending`/`Missing` segment, verifies size and SHA-256, parses records with `parse_segment` and
#    inserts them into `bronze.gateway_records` (insert-only `MERGE` on `record_id`).
# 4. Marks segments `Processed`, `Missing` (retried up to `landing.maxSegmentAttempts`) or `Quarantined`.
# 
# Only files listed in a committed manifest are read; re-running the notebook never duplicates Bronze rows.

# CELL ********************

configure_spark("bronze")
cfg = load_config()
spark = get_spark()
landing_root = cfg["landing"]["root"]
lookback = int(lookback_days) if lookback_days else int(cfg["landing"]["manifestLookbackDays"])
manifest_limit = int(max_manifests) if max_manifests else int(cfg["landing"]["maxManifestsPerRun"])
max_attempts = int(cfg["landing"]["maxSegmentAttempts"])
max_record_chars = int(cfg["bronze"]["maxRecordChars"])
dedup_days = int(cfg["bronze"]["dedupLookbackDays"])
batch_id = new_batch_id()
batch_started = utc_now()
parameters = {"lookback_days": lookback, "reprocess_from": reprocess_from, "reprocess_to": reprocess_to,
              "max_manifests": manifest_limit}


def quarantine_file(relative_path: str, reason: str, details: str, segment: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Copy a file to processing/quarantine and return an ops.quarantined_files row."""
    now = utc_now()
    target = f"{QUARANTINE_ROOT}/{now:%Y/%m/%d}/{batch_id}/{relative_path.split('/landing/', 1)[-1]}"
    copied = None
    try:
        if os.path.exists(mount_path(relative_path)):
            nbutils().fs.cp(relative_path, target)
            copied = target
    except Exception as exc:
        details = f"{details}; copy failed: {exc}"
    segment = segment or {}
    return {
        "quarantine_id": sha256_hex(relative_path, reason), "segment_id": segment.get("segment_id"),
        "original_path": relative_path, "quarantine_path": copied, "reason": reason,
        "details": truncate(details, 4000), "detected_utc": now, "batch_id": batch_id,
        "server_name": segment.get("server_name"), "server_id": segment.get("server_id"),
        "gateway_id": segment.get("gateway_id"), "log_type": segment.get("log_type"),
    }

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

with ProcessingRun("bronze", "nb_gwmon_ingest", batch_id, parameters) as run:
    quarantined_rows: List[Dict[str, Any]] = []

    # --- optional backfill: re-ingest segments uploaded in a date range (raw files must still exist) --------------
    if reprocess_from:
        # Strict YYYY-MM-DD parsing: the values are interpolated into SQL below.
        lower = date.fromisoformat(str(reprocess_from).strip()).isoformat()
        upper = date.fromisoformat(str(reprocess_to).strip()).isoformat() if reprocess_to else utc_now().date().isoformat()
        if upper < lower:
            raise ValueError(f"reprocess_to ({upper}) is before reprocess_from ({lower})")
        spark.sql(
            "UPDATE ops.segment_registry SET status = 'Pending', attempts = 0, error = 'reprocess requested' "
            f"WHERE to_date(uploaded_utc) BETWEEN DATE'{lower}' AND DATE'{upper}'"
        )
        run.details["reprocess"] = {"from": lower, "to": upper}

    # --- 1. run telemetry → ops.agent_runs ------------------------------------------------------------------------
    telemetry_paths = list_landing_documents(landing_root, "telemetry", ".run.json", lookback)
    known_run_ids = {
        r["run_id"] for r in spark.sql(
            f"SELECT run_id FROM ops.agent_runs WHERE received_utc >= current_timestamp() - INTERVAL {lookback + 2} DAYS"
        ).collect()
    }
    agent_rows = []
    for path in telemetry_paths:
        run_id = os.path.basename(path).split(".")[0].lower()
        if run_id in known_run_ids:
            continue
        try:
            agent_rows.append(agent_run_row(read_json_relative(path), path, utc_now()))
        except Exception as exc:
            quarantined_rows.append(quarantine_file(path, "invalid-telemetry", str(exc)))
    if agent_rows:
        merge_upsert(to_df(agent_rows, "ops.agent_runs"), "ops.agent_runs", ["run_id"])
    run.details["telemetry_registered"] = len(agent_rows)

    # --- 2. manifests → registries ------------------------------------------------------------------------------
    manifest_paths = list_landing_documents(landing_root, "manifests", ".manifest.json", lookback)
    known_manifests = {
        r["manifest_path"] for r in spark.sql(
            f"SELECT manifest_path FROM ops.manifest_registry "
            f"WHERE registered_utc >= current_timestamp() - INTERVAL {lookback + 2} DAYS"
        ).collect()
    }
    new_manifests = [p for p in manifest_paths if p not in known_manifests][:manifest_limit]
    manifest_rows, segment_rows = [], []
    for path in new_manifests:
        now = utc_now()
        try:
            document = read_json_relative(path)
            problems = validate_manifest(document)
        except Exception as exc:
            document, problems = None, [f"unreadable: {exc}"]
        if problems:
            manifest_rows.append({"manifest_path": path, "status": "Invalid", "error": truncate("; ".join(problems), 4000),
                                  "registered_utc": now, "batch_id": batch_id})
            quarantined_rows.append(quarantine_file(path, "invalid-manifest", "; ".join(problems)))
            continue
        manifest_row, segments = manifest_registry_rows(document, path, landing_root, batch_id, now)
        manifest_rows.append(manifest_row)
        segment_rows.extend(segments)
    if manifest_rows:
        merge_upsert(to_df(manifest_rows, "ops.manifest_registry"), "ops.manifest_registry", ["manifest_path"])
    if segment_rows:
        # a replayed manifest lists the same segment ids: keep the existing registry status
        merge_insert_only(to_df(segment_rows, "ops.segment_registry").dropDuplicates(["segment_id"]),
                          "ops.segment_registry", ["segment_id"])
    run.details["manifests_registered"] = len(manifest_rows)
    run.details["segments_registered"] = len(segment_rows)

    # --- 3. pending segments -------------------------------------------------------------------------------------
    pending = [r.asDict() for r in spark.sql(
        f"SELECT * FROM ops.segment_registry WHERE status IN ('Pending', 'Missing') AND coalesce(attempts, 0) < {max_attempts}"
    ).collect()]
    present = [s for s in pending if os.path.exists(mount_path(s["raw_path"]))]
    missing = [s for s in pending if not os.path.exists(mount_path(s["raw_path"]))]
    run.details["segments_pending"] = len(pending)
    run.details["segments_missing"] = len(missing)

    registry_updates: List[Dict[str, Any]] = []
    for segment in missing:
        attempts = int(segment.get("attempts") or 0) + 1
        segment.update(status="Missing", attempts=attempts, batch_id=batch_id,
                       error=f"raw file not found (attempt {attempts}/{max_attempts})")
        registry_updates.append(segment)

    bronze_written = 0
    if present:
        segment_by_path = {s["raw_path"]: s for s in present}
        binary = (spark.read.format("binaryFile").load([s["raw_path"] for s in present])
                  .withColumn("relative_path", F.regexp_extract(F.col("path"), r"(Files/.*)$", 1))
                  .select("relative_path", "content"))
        broadcast_segments = spark.sparkContext.broadcast(segment_by_path)

        def parse_partition(rows):
            segments = broadcast_segments.value
            for row in rows:
                segment = segments.get(row["relative_path"])
                if segment is None:
                    continue
                records, result = bronze_rows_for_segment(bytes(row["content"]), segment, batch_id, batch_started,
                                                          max_record_chars)
                yield ("result", {"segment_id": segment["segment_id"], **result})
                for record in records:
                    yield ("record", record)

        parsed = binary.rdd.mapPartitions(parse_partition).persist()
        names = columns_of("bronze.gateway_records")
        records_df = spark.createDataFrame(
            parsed.filter(lambda item: item[0] == "record").map(lambda item: tuple(item[1].get(n) for n in names)),
            spark_schema("bronze.gateway_records"),
        )
        merge_insert_only(records_df, "bronze.gateway_records", ["record_id"],
                          target_filter=f"t.ingest_date >= date_sub(current_date(), {dedup_days})")
        results = {r["segment_id"]: r for _, r in parsed.filter(lambda item: item[0] == "result").collect()}
        parsed.unpersist()

        for segment in present:
            result = results.get(segment["segment_id"])
            if result is None:
                attempts = int(segment.get("attempts") or 0) + 1
                segment.update(status="Missing", attempts=attempts, batch_id=batch_id, error="file listed but not read")
            elif result["status"] == "Quarantined":
                segment.update(status="Quarantined", attempts=int(segment.get("attempts") or 0) + 1,
                               processed_utc=utc_now(), batch_id=batch_id, error=result["reason"])
                quarantined_rows.append(quarantine_file(segment["raw_path"], result["reason"],
                                                        f"segment {segment['segment_id']}", segment))
            else:
                segment.update(status="Processed", attempts=int(segment.get("attempts") or 0) + 1,
                               record_count=result["record_count"], malformed_count=result["malformed_count"],
                               processed_utc=utc_now(), batch_id=batch_id, error=None)
                bronze_written += int(result["record_count"])
                run.metrics["rows_rejected"] += int(result["malformed_count"])
            registry_updates.append(segment)

    if registry_updates:
        merge_upsert(to_df(registry_updates, "ops.segment_registry"), "ops.segment_registry", ["segment_id"])
    if quarantined_rows:
        merge_upsert(to_df(quarantined_rows, "ops.quarantined_files"), "ops.quarantined_files", ["quarantine_id"])

    run.metrics["rows_read"] = len(present)
    run.metrics["rows_written"] = bronze_written
    run.details["segments_processed"] = sum(1 for s in registry_updates if s["status"] == "Processed")
    run.details["segments_quarantined"] = sum(1 for s in registry_updates if s["status"] == "Quarantined")
    bronze_summary = run.summary()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# ## 3. Silver — Bronze to Silver
# 
# Reads Bronze batches newer than the `silver` watermark, parses and types every record with the library
# normalizers, applies redaction rules, and inserts rows into the Silver tables with an insert-only `MERGE` on the
# content-addressed `record_key` (duplicate uploads collapse here). Records that cannot be parsed go to
# `ops.rejected_records`; unknown columns are logged in `ops.schema_drift`. The watermark only moves forward when
# every table was written successfully.

# CELL ********************

configure_spark("silver")
cfg = load_config()
spark = get_spark()
silver_settings = dict(cfg["silver"])
redaction_config = {"redaction": cfg.get("redaction", {})}
previous_watermark = rebuild_from_batch if rebuild_from_batch else (get_watermark("silver") or "")
processed_at = utc_now()

SILVER_TABLES = [
    "gateway_logs", "artifact_traces", "query_starts", "query_executions", "query_aggregations",
    "system_counters", "mashup_logs", "mashup_container_profiles", "gateway_metadata", "gateway_cluster_members",
]

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

with ProcessingRun("silver", "nb_gwmon_ingest", parameters={"from": previous_watermark}) as run:
    bronze = spark.table("bronze.gateway_records").where(F.col("ingest_batch_id") > F.lit(previous_watermark))
    new_watermark = bronze.agg(F.max("ingest_batch_id").alias("wm")).first()["wm"]
    run.batch_id = new_watermark
    run.details["watermark_from"] = previous_watermark
    run.details["watermark_to"] = new_watermark

    if new_watermark is not None:
        bronze_columns = columns_of("bronze.gateway_records")

        def normalize_partition(rows):
            redactor = Redactor(redaction_config)
            for row in rows:
                for table, values in silver_rows_for_bronze(row.asDict(), silver_settings, redactor, processed_at):
                    yield (table, values)

        normalized = bronze.rdd.mapPartitions(normalize_partition).persist()
        written: Dict[str, int] = {}

        for table in SILVER_TABLES:
            table_key = f"silver.{table}"
            names = columns_of(table_key)
            frame = spark.createDataFrame(
                normalized.filter(lambda item, t=table: item[0] == t)
                          .map(lambda item, n=names: tuple(item[1].get(c) for c in n)),
                spark_schema(table_key),
            ).dropDuplicates(["record_key"])
            count = frame.count()
            if count == 0:
                continue
            if "event_month" in TABLES[table_key]["partition_by"]:
                months = [r["event_month"] for r in frame.select("event_month").distinct().collect()]
                month_list = ", ".join(str(int(m)) for m in months)
                merge_insert_only(frame, table_key, ["record_key"],
                                  target_filter=f"t.event_month = s.event_month AND t.event_month IN ({month_list})")
            else:
                merge_insert_only(frame, table_key, ["record_key"])
            written[table] = count

        rejected_names = columns_of("ops.rejected_records")
        rejected = spark.createDataFrame(
            normalized.filter(lambda item: item[0] == "_rejected")
                      .map(lambda item: tuple(item[1].get(c) for c in rejected_names)),
            spark_schema("ops.rejected_records"),
        ).dropDuplicates(["record_id"])
        rejected_count = rejected.count()
        if rejected_count:
            merge_insert_only(rejected, "ops.rejected_records", ["record_id"])

        drift_rows = normalized.filter(lambda item: item[0] == "_drift").map(lambda item: item[1]).collect()
        if drift_rows:
            aggregated: Dict[Tuple[str, str], Dict[str, Any]] = {}
            for row in drift_rows:
                key = (row["log_type"], row["column_name"])
                entry = aggregated.setdefault(key, {
                    "log_type": row["log_type"], "column_name": row["column_name"], "first_seen_utc": processed_at,
                    "last_seen_utc": processed_at, "occurrences": 0, "sample_value": row.get("sample_value"),
                    "first_batch_id": row.get("batch_id"),
                })
                entry["occurrences"] += 1
            drift_view = "_gwmon_drift_" + uuid.uuid4().hex[:8]
            conform(to_df(list(aggregated.values()), "ops.schema_drift"), "ops.schema_drift").createOrReplaceTempView(drift_view)
            spark.sql(
                f"MERGE INTO ops.schema_drift AS t USING {drift_view} AS s "
                "ON t.log_type = s.log_type AND t.column_name = s.column_name "
                "WHEN MATCHED THEN UPDATE SET t.last_seen_utc = s.last_seen_utc, t.occurrences = t.occurrences + s.occurrences "
                "WHEN NOT MATCHED THEN INSERT *"
            )
            run.details["schema_drift_columns"] = sorted(f"{k[0]}:{k[1]}" for k in aggregated)

        normalized.unpersist()
        run.metrics["rows_written"] = sum(written.values())
        run.metrics["rows_rejected"] = rejected_count
        run.details["written"] = written
        set_watermark("silver", new_watermark, run.run_id)

    silver_summary = run.summary()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# ## 4. Gold — Silver to Gold (Direct Lake tables)
# 
# * Facts (`logs`, `queries`, `query_datasources`, `mashup_logs`, `system_counters`) are **recomputed per affected
#   month partition** with `replaceWhere` — idempotent and safe for late-arriving data.
# * `requests` is recomputed for every request id touched by an affected month (`MERGE`).
# * Dimensions (`calendar`, `time_of_day`, `gateways`), `logs_artifact_trace`, `mashup_container_profile` and the
#   ingestion-health tables are rebuilt.
# * Every string is capped to the Direct Lake limit; tables use V-Order.
# * Optionally reframes the Direct Lake semantic model at the end (`reframe_semantic_model`).

# CELL ********************

configure_spark("gold")
cfg = load_config()
gold_cfg = cfg["gold"]
spark = get_spark()
now = utc_now()
today = now.date()
window_month = event_month_of(today - timedelta(days=int(gold_cfg["windowDays"])))
log_types = list(gold_cfg["logTypes"])
include_ids = [g.lower() for g in gold_cfg.get("gatewayInclude") or []]
max_log, max_query, max_error = (int(gold_cfg["maxLogTextLength"]), int(gold_cfg["maxQueryTextLength"]),
                                 int(gold_cfg["maxErrorTextLength"]))
rebuild = str(rebuild_gold).lower() == "true"
gold_watermark = "" if rebuild else (get_watermark("gold") or "")
reframe = str(reframe_semantic_model).lower() == "true" or bool(cfg["semanticModel"].get("reframeAfterGold"))
model_name = semantic_model_name or cfg["semanticModel"]["name"]

SILVER_FACT_SOURCES = ["gateway_logs", "artifact_traces", "query_starts", "query_executions", "system_counters",
                       "mashup_logs", "mashup_container_profiles", "gateway_metadata", "gateway_cluster_members"]
silver_high_watermark = max(
    (spark.sql(f"SELECT max(ingest_batch_id) AS m FROM silver.{t}").first()["m"] or "") for t in SILVER_FACT_SOURCES
)


def tod(column: str):
    """Time of day on 1899-12-30 with second precision (original Time.ToText(..., 'HH:mm:ss'))."""
    return F.expr(f"make_timestamp(1899, 12, 30, hour({column}), minute({column}), second({column}))")


def tod_fraction(column: str):
    """Time of day keeping the fractional seconds (original DateTime.Time([EndTime]))."""
    return F.expr(
        f"make_timestamp(1899, 12, 30, hour({column}), minute({column}), "
        f"cast(second({column}) + (unix_micros({column}) % 1000000) / 1000000.0 as decimal(8,6)))"
    )


def guid_after(column, pattern: str):
    """First GUID captured by ``pattern`` in ``column`` or null."""
    extracted = F.regexp_extract(column, pattern, 1)
    return F.when(extracted != "", extracted)


def changed(table: str):
    frame = spark.table(f"silver.{table}")
    return frame.where(F.col("ingest_batch_id") > F.lit(gold_watermark)) if gold_watermark else frame


def months_of(frame, column: str = "event_month") -> List[int]:
    return sorted(int(r[0]) for r in frame.select(column).distinct().collect()
                  if r[0] is not None and int(r[0]) >= window_month)


def only_included(frame):
    return frame.where(F.col("gateway_id").isin(include_ids)) if include_ids else frame


datasource_schema = T.ArrayType(T.StructType([T.StructField("kind", T.StringType()), T.StructField("path", T.StringType())]))
datasources_udf = F.udf(lambda text: [{"kind": k, "path": p} for k, p in parse_datasources(text)], datasource_schema)
DATASET_ID_RE = r"dataset_?id[^0-9a-f]{0,6}([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"
WORKSPACE_ID_RE = r"workspace_?id[^0-9a-f]{0,6}([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})"

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

with ProcessingRun("gold", "nb_gwmon_ingest", silver_high_watermark,
                   {"rebuild_gold": rebuild, "window_month": window_month, "reframe": reframe}) as run:
    written: Dict[str, Any] = {}

    # --- Logs -----------------------------------------------------------------------------------------------------
    logs_source = only_included(spark.table("silver.gateway_logs").where(F.col("log_type").isin(log_types)))
    logs_months = months_of(logs_source if rebuild else only_included(changed("gateway_logs").where(F.col("log_type").isin(log_types))))
    if logs_months:
        logs_df = logs_source.where(F.col("event_month").isin(logs_months)).select(
            "record_key", "activity_id", "activity_type", "client_activity_id", "current_gateway_client_pipeline_id",
            F.col("event_date").alias("date"), F.date_trunc("minute", "event_utc").alias("date_time"),
            F.substring("event_text", 1, max_log).alias("event_text"), "event_type", "gateway_id", "hash",
            tod("event_utc").alias("hour"), "instance", "level", F.col("source_file_name").alias("log_file_name"),
            "root_activity_id", "root_gateway_client_pipeline_id",
            (F.hour("event_utc") * 100 + F.minute("event_utc")).alias("time_id"), "log_type", "event_utc",
            "server_id", "event_month",
        )
        replace_partitions(cap_strings(logs_df), "gold.logs", "event_month", logs_months)
    written["logs_months"] = logs_months

    # --- Queries and data sources ---------------------------------------------------------------------------------
    starts_all = only_included(spark.table("silver.query_starts").where(F.col("event_month") >= window_month))
    if rebuild:
        query_months = months_of(starts_all)
    else:
        touched_ids = (changed("query_starts").select("query_tracking_id")
                       .union(changed("query_executions").select("query_tracking_id")).distinct())
        query_months = months_of(starts_all.join(touched_ids, "query_tracking_id", "left_semi"))
    if query_months:
        ids_in_months = starts_all.where(F.col("event_month").isin(query_months)).select("query_tracking_id").distinct()
        latest_start = Window.partitionBy("query_tracking_id").orderBy(F.col("query_start_utc").desc(), F.col("record_key").desc())
        chosen = (starts_all.join(ids_in_months, "query_tracking_id", "left_semi")
                  .withColumn("_rn", F.row_number().over(latest_start)).where("_rn = 1").drop("_rn")
                  .where(F.col("event_month").isin(query_months))
                  .select("gateway_id", "query_tracking_id", "request_id", "query_type", "query_start_utc", "data_source",
                          "query_text", "evaluation_context", "source_file_name", "server_id", "event_month"))
        latest_execution = Window.partitionBy("gateway_id", "query_tracking_id").orderBy(
            F.coalesce("data_processing_end_utc", "query_execution_end_utc").desc_nulls_last(), F.col("record_key").desc())
        executions = (spark.table("silver.query_executions").join(ids_in_months, "query_tracking_id", "left_semi")
                      .withColumn("_rn", F.row_number().over(latest_execution)).where("_rn = 1")
                      .select("gateway_id", "query_tracking_id", "query_execution_end_utc", "query_execution_duration_ms",
                              "data_reading_and_serialization_duration_ms", "spooling_disk_writing_duration_ms",
                              "spooling_disk_reading_duration_ms", "spooling_total_data_size_bytes",
                              "data_processing_end_utc", "data_processing_duration_ms", "success", "error_message"))
        artifact = (spark.table("silver.artifact_traces").where(F.col("event_month") >= window_month)
                    .groupBy("root_activity_id")
                    .agg(F.max("dataset_id").alias("lat_dataset_id"), F.max("workspace_id").alias("lat_workspace_id")))
        joined = (chosen.join(executions, ["gateway_id", "query_tracking_id"], "left")
                  .join(artifact, F.col("request_id") == F.col("root_activity_id"), "left")
                  .withColumn("_end", F.coalesce("data_processing_end_utc", "query_execution_end_utc"))
                  .withColumn("_ds", datasources_udf("data_source")))
        eval_lower = F.lower(F.col("evaluation_context"))
        queries_df = joined.select(
            "data_processing_duration_ms", "data_reading_and_serialization_duration_ms",
            F.coalesce("lat_dataset_id", guid_after(eval_lower, DATASET_ID_RE)).alias("dataset_id"),
            F.concat_ws(";", F.array_sort(F.array_distinct(F.expr("transform(_ds, x -> x.kind)")))).alias("datasources"),
            F.date_trunc("minute", "query_start_utc").alias("date_time"), F.to_date("_end").alias("end_date"),
            tod_fraction("_end").alias("end_time"), F.substring("error_message", 1, max_error).alias("error_message"),
            F.col("source_file_name").alias("file_name"), "gateway_id", "query_execution_duration_ms",
            F.substring("query_text", 1, max_query).alias("query_text"), "query_tracking_id", "query_type", "request_id",
            "spooling_disk_reading_duration_ms", "spooling_disk_writing_duration_ms", "spooling_total_data_size_bytes",
            F.to_date("query_start_utc").alias("start_date"), tod("query_start_utc").alias("start_time"), "success",
            (F.hour("query_start_utc") * 100 + F.minute("query_start_utc")).alias("time_id"),
            F.when(F.col("_end").isNotNull(),
                   F.bround((F.expr("unix_micros(_end)") - F.expr("unix_micros(query_start_utc)")) / 1000.0, 0).cast("bigint")
                   ).alias("total_query_execution_ms"),
            F.coalesce("lat_workspace_id", guid_after(eval_lower, WORKSPACE_ID_RE)).alias("workspace_id"),
            "evaluation_context", "query_start_utc", F.col("_end").alias("query_end_utc"), "server_id", "event_month",
        )
        replace_partitions(cap_strings(queries_df), "gold.queries", "event_month", query_months)
        datasources_df = (chosen.select("query_tracking_id", "event_month", F.explode(datasources_udf("data_source")).alias("d"))
                          .select("query_tracking_id", F.col("d.kind").alias("datasource_kind"),
                                  F.col("d.path").alias("datasource_path"), "event_month").distinct())
        replace_partitions(cap_strings(datasources_df), "gold.query_datasources", "event_month", query_months)
    written["query_months"] = query_months

    # --- Requests (materialized calculated table) -----------------------------------------------------------------
    touched_months = sorted(set(logs_months) | set(query_months))
    if rebuild or touched_months:
        logs_gold = spark.table("gold.logs")
        queries_gold = spark.table("gold.queries")
        if not rebuild:
            ids = (logs_gold.where(F.col("event_month").isin(touched_months)).select(F.col("root_activity_id").alias("request_id"))
                   .union(queries_gold.where(F.col("event_month").isin(touched_months)).select("request_id"))
                   .where(F.col("request_id").isNotNull() & (F.col("request_id") != "")).distinct())
            logs_gold = logs_gold.join(ids.withColumnRenamed("request_id", "root_activity_id"), "root_activity_id", "left_semi")
            queries_gold = queries_gold.join(ids, "request_id", "left_semi")
        log_part = (logs_gold.where(F.col("root_activity_id").isNotNull() & (F.col("root_activity_id") != ""))
                    .groupBy(F.col("root_activity_id").alias("request_id"))
                    .agg(F.min(F.date_trunc("second", "event_utc")).alias("start"),
                         F.max(F.date_trunc("second", "event_utc")).alias("end"))
                    .withColumn("has_q", F.lit(0)))
        query_part = (queries_gold.where(F.col("request_id").isNotNull() & (F.col("request_id") != ""))
                      .groupBy("request_id")
                      .agg(F.min(F.date_trunc("second", "query_start_utc")).alias("start"),
                           F.max(F.date_trunc("second", "query_end_utc")).alias("end"))
                      .withColumn("has_q", F.lit(1)))
        query_durations = query_part.select(
            "request_id",
            F.when(F.col("start").isNotNull() & F.col("end").isNotNull(),
                   F.expr("unix_seconds(end) - unix_seconds(start)")).alias("duration_queries_s"))
        requests_df = (log_part.unionByName(query_part).groupBy("request_id")
                       .agg(F.min("start").alias("request_start"), F.max("end").alias("request_end"), F.max("has_q").alias("has_q"))
                       .where(F.col("request_start").isNotNull())
                       .join(query_durations, "request_id", "left")
                       .select("request_id", "request_start", "request_end",
                               F.when(F.col("request_end").isNotNull(),
                                      F.expr("unix_seconds(request_end) - unix_seconds(request_start)")).alias("duration_s"),
                               "duration_queries_s", F.to_date("request_start").alias("date"),
                               F.when(F.col("has_q") == 1, "Y").otherwise("N").alias("has_queries"),
                               (F.year("request_start") * 100 + F.month("request_start")).alias("event_month")))
        if rebuild:
            overwrite_table(cap_strings(requests_df), "gold.requests")
        else:
            merge_upsert(cap_strings(requests_df), "gold.requests", ["request_id"])
    spark.sql(f"DELETE FROM gold.requests WHERE event_month < {window_month}")

    # --- Mashup logs ----------------------------------------------------------------------------------------------
    mashup_source = only_included(spark.table("silver.mashup_logs"))
    mashup_months = months_of(mashup_source if rebuild else only_included(changed("mashup_logs")))
    if mashup_months:
        mashup_df = mashup_source.where(F.col("event_month").isin(mashup_months)).select(
            "record_key", "action", "action_detail", "action_group", "activity_id",
            F.substring("command_text", 1, max_query).alias("command_text"), "command_timeout", "connection_timeout",
            "container_id", F.col("event_date").alias("date"), F.date_trunc("minute", "start_utc").alias("date_time"),
            "duration_ms", "engine_edition", "error_yn", F.substring("exception", 1, max_error).alias("exception"),
            F.col("source_file_name").alias("file_name"), "firewall_group", "gateway_id", "identity", "non_fatal_error",
            "pid", "process", "product_version", "resource_kind", "resource_path", "row_count",
            tod("start_utc").alias("time_of_day"), (F.hour("start_utc") * 100 + F.minute("start_utc")).alias("time_id"),
            "pending_count", "pool_count", "running_count", "server_id", "event_month",
        )
        replace_partitions(cap_strings(mashup_df), "gold.mashup_logs", "event_month", mashup_months)
    written["mashup_months"] = mashup_months

    # --- System counters ------------------------------------------------------------------------------------------
    counters_source = only_included(spark.table("silver.system_counters"))
    counter_months = months_of(counters_source if rebuild else only_included(changed("system_counters")))
    if counter_months:
        counters_df = counters_source.where(F.col("event_month").isin(counter_months)).select(
            "record_key", F.col("aggregation_end_utc").alias("aggregation_end_time_utc"),
            F.col("aggregation_start_utc").alias("aggregation_start_time_utc"), "average_value", "counter_name",
            F.to_date("aggregation_end_utc").alias("date"), F.col("source_file_name").alias("file_name"), "gateway_id",
            "max_value", "min_value",
            (F.hour("aggregation_end_utc") * 100 + F.minute("aggregation_end_utc")).alias("tme_id"),
            "server_id", "event_month",
        )
        replace_partitions(cap_strings(counters_df), "gold.system_counters", "event_month", counter_months)
    written["counter_months"] = counter_months

    # --- Window enforcement for partitioned facts -----------------------------------------------------------------
    for fact in ("gold.logs", "gold.queries", "gold.query_datasources", "gold.mashup_logs", "gold.system_counters"):
        spark.sql(f"DELETE FROM {fact} WHERE event_month < {window_month}")

    # --- LogsArtifactTrace ----------------------------------------------------------------------------------------
    latest_trace = Window.partitionBy("gateway_id", "root_activity_id", "dataset_id").orderBy(F.col("event_utc").desc())
    lat_df = (spark.table("silver.artifact_traces").where(F.col("event_month") >= window_month)
              .withColumn("_rn", F.row_number().over(latest_trace)).where("_rn = 1")
              .select("current_activity_id", "dataset_id", "gateway_id", F.col("source_file_name").alias("log_file_name"),
                      "query_type", "root_activity_id", "sku", "workspace_id"))
    overwrite_table(cap_strings(only_included(lat_df)), "gold.logs_artifact_trace")

    # --- Mashup container profile (latest snapshot per gateway) ---------------------------------------------------
    profiles = spark.table("silver.mashup_container_profiles")
    latest_snapshot = Window.partitionBy("gateway_id").orderBy(F.col("snapshot_utc").desc_nulls_last(), F.col("snapshot_key").desc())
    top_snapshots = (profiles.select("gateway_id", "snapshot_key", "snapshot_utc").distinct()
                     .withColumn("_rn", F.row_number().over(latest_snapshot)).where("_rn = 1").select("gateway_id", "snapshot_key"))
    profile_df = (profiles.join(top_snapshots, ["gateway_id", "snapshot_key"]).dropDuplicates(["gateway_id", "pool_type_id"])
                  .select("cache_time_to_live_in_minute", "container_max_commit_in_mb", "container_max_count",
                          "container_max_working_set_in_mb", "container_time_to_live_in_minute", "data_cache_max_size_in_mb",
                          "data_cache_time_to_live_in_minute", "enable_caching", "gateway_id",
                          F.col("pool_type").alias("mashup_container_pool_type"),
                          F.col("pool_type_id").alias("mashup_container_pool_type_id"), "metadata_cache_max_size_in_mb",
                          "metadata_cache_time_to_live_in_minute", "session_time_to_live_in_minute", "snapshot_utc"))
    overwrite_table(cap_strings(only_included(profile_df)), "gold.mashup_container_profile")

    # --- Ingestion health tables ----------------------------------------------------------------------------------
    ingestion_since = F.lit(now - timedelta(days=int(gold_cfg["ingestionWindowDays"])))
    registry = spark.table("ops.segment_registry")
    uploads_df = registry.where(F.col("uploaded_utc") >= ingestion_since).select(
        "segment_id", "server_id", "gateway_id", "environment", "cluster_id", "log_type", "source_file_name", "raw_path",
        "byte_count", "record_count", "malformed_count", "source_last_write_utc", "uploaded_utc",
        F.to_date("uploaded_utc").alias("upload_date"), "processed_utc", "status", "attempts",
        ((F.expr("unix_seconds(uploaded_utc)") - F.expr("unix_seconds(source_last_write_utc)")) / 60.0).alias("upload_latency_minutes"),
        ((F.expr("unix_seconds(processed_utc)") - F.expr("unix_seconds(uploaded_utc)")) / 60.0).alias("processing_latency_minutes"),
        ((F.expr("unix_seconds(processed_utc)") - F.expr("unix_seconds(source_last_write_utc)")) / 60.0).alias("total_latency_minutes"),
        "manifest_run_id", "error",
    )
    overwrite_table(cap_strings(uploads_df), "gold.ingestion_uploads")

    agent_runs = spark.table("ops.agent_runs")
    agent_runs_df = agent_runs.where(F.col("started_utc") >= ingestion_since).select(
        "run_id", "server_id", "environment", "agent_version", "agent_instance_id", "started_utc", "ended_utc",
        F.to_date("started_utc").alias("run_date"), (F.col("duration_ms") / 1000.0).alias("duration_seconds"), "status",
        "trigger", "auth_mode", "files_scanned", "segments_uploaded", "bytes_uploaded", "errors", "warnings",
        F.substring("issues_json", 1, 4000).alias("issues_summary"),
    )
    overwrite_table(cap_strings(agent_runs_df), "gold.ingestion_agent_runs")

    processing_df = spark.table("ops.processing_runs").where(F.col("started_utc") >= ingestion_since).select(
        "run_id", "stage", "notebook", "started_utc", "ended_utc", F.to_date("started_utc").alias("run_date"),
        ((F.expr("unix_micros(ended_utc)") - F.expr("unix_micros(started_utc)")) / 1000000.0).alias("duration_seconds"),
        "status", "rows_read", "rows_written", "rows_rejected", "batch_id", "error_message",
    )
    overwrite_table(cap_strings(processing_df), "gold.ingestion_processing_runs")

    def issue_id(*columns):
        return F.sha2(F.concat_ws("|", *[F.coalesce(F.col(c).cast("string"), F.lit("")) for c in columns]), 256)

    rejected_issues = (spark.table("ops.rejected_records").where(F.col("detected_utc") >= ingestion_since)
                       .groupBy("segment_id", "reason", "log_type", "gateway_id", "server_id")
                       .agg(F.max("detected_utc").alias("detected_utc"), F.count(F.lit(1)).alias("occurrences"),
                            F.first("raw_text").alias("details"), F.max("batch_id").alias("batch_id"))
                       .join(registry.select("segment_id", "raw_path"), "segment_id", "left")
                       .select(F.lit("Rejected Record").alias("issue_type"), F.lit("Warning").alias("severity"),
                               "detected_utc", "server_id", "gateway_id", "log_type",
                               F.coalesce("raw_path", "segment_id").alias("object_path"), "reason",
                               F.substring("details", 1, 1000).alias("details"), "occurrences", "batch_id", "segment_id"))
    quarantine_issues = (spark.table("ops.quarantined_files").where(F.col("detected_utc") >= ingestion_since)
                         .select(F.when(F.col("reason").startswith("orphan"), "Orphan File").otherwise("Quarantined File").alias("issue_type"),
                                 F.when(F.col("reason").startswith("orphan"), "Warning").otherwise("Error").alias("severity"),
                                 "detected_utc", "server_id", "gateway_id", "log_type",
                                 F.col("original_path").alias("object_path"), "reason", "details",
                                 F.lit(1).cast("bigint").alias("occurrences"), "batch_id", "segment_id"))
    max_attempts = int(cfg["landing"]["maxSegmentAttempts"])
    missing_issues = (registry.where(F.col("status") == "Missing")
                      .select(F.lit("Missing Segment").alias("issue_type"),
                              F.when(F.col("attempts") >= max_attempts, "Error").otherwise("Warning").alias("severity"),
                              F.col("first_seen_utc").alias("detected_utc"), "server_id", "gateway_id", "log_type",
                              F.col("raw_path").alias("object_path"), F.coalesce("error", F.lit("raw file not found")).alias("reason"),
                              F.lit(None).cast("string").alias("details"), F.lit(1).cast("bigint").alias("occurrences"),
                              "batch_id", "segment_id"))
    agent_issues = (agent_runs.where((F.col("started_utc") >= ingestion_since) & F.col("status").isin("Failed", "PartiallySucceeded"))
                    .select(F.when(F.col("status") == "Failed", "Agent Run Failed").otherwise("Agent Run Warning").alias("issue_type"),
                            F.when(F.col("status") == "Failed", "Error").otherwise("Warning").alias("severity"),
                            F.col("ended_utc").alias("detected_utc"), "server_id", F.lit(None).cast("string").alias("gateway_id"),
                            F.lit(None).cast("string").alias("log_type"), F.col("server_name").alias("object_path"),
                            F.col("status").alias("reason"), F.substring("issues_json", 1, 1000).alias("details"),
                            F.coalesce("errors", F.lit(1)).alias("occurrences"), F.col("run_id").alias("batch_id"),
                            F.lit(None).cast("string").alias("segment_id")))
    processing_issues = (spark.table("ops.processing_runs").where((F.col("started_utc") >= ingestion_since) & (F.col("status") == "Failed"))
                         .select(F.lit("Processing Failure").alias("issue_type"), F.lit("Error").alias("severity"),
                                 F.coalesce("ended_utc", "started_utc").alias("detected_utc"),
                                 F.lit(None).cast("string").alias("server_id"), F.lit(None).cast("string").alias("gateway_id"),
                                 F.lit(None).cast("string").alias("log_type"), F.col("notebook").alias("object_path"),
                                 F.col("stage").alias("reason"), F.substring("error_message", 1, 1000).alias("details"),
                                 F.lit(1).cast("bigint").alias("occurrences"), "batch_id", F.col("run_id").alias("segment_id")))
    drift_issues = (spark.table("ops.schema_drift").where(F.col("last_seen_utc") >= ingestion_since)
                    .select(F.lit("Schema Drift").alias("issue_type"), F.lit("Info").alias("severity"),
                            F.col("last_seen_utc").alias("detected_utc"), F.lit(None).cast("string").alias("server_id"),
                            F.lit(None).cast("string").alias("gateway_id"), "log_type",
                            F.col("log_type").alias("object_path"), F.col("column_name").alias("reason"),
                            F.col("sample_value").alias("details"), "occurrences", F.col("first_batch_id").alias("batch_id"),
                            F.col("column_name").alias("segment_id")))
    issues_df = (rejected_issues.unionByName(quarantine_issues).unionByName(missing_issues).unionByName(agent_issues)
                 .unionByName(processing_issues).unionByName(drift_issues)
                 .withColumn("issue_id", issue_id("issue_type", "segment_id", "object_path", "reason", "batch_id"))
                 .withColumn("detected_date", F.to_date("detected_utc"))
                 .dropDuplicates(["issue_id"]))
    overwrite_table(cap_strings(issues_df), "gold.ingestion_issues")

    latest_run = Window.partitionBy("server_id").orderBy(F.col("ended_utc").desc_nulls_last(), F.col("started_utc").desc())
    run_latest = (agent_runs.where(F.col("server_id").isNotNull()).withColumn("_rn", F.row_number().over(latest_run)).where("_rn = 1")
                  .select("server_id", "server_name", "server_fqdn", "environment", "agent_instance_id", "agent_version",
                          "time_zone_id", "utc_offset_minutes", F.col("status").alias("last_run_status")))
    run_stats = (agent_runs.where(F.col("server_id").isNotNull()).groupBy("server_id")
                 .agg(F.min("started_utc").alias("first_seen_utc"), F.max("ended_utc").alias("last_run_utc"),
                      F.max(F.when(F.col("status").isin("Succeeded", "PartiallySucceeded"), F.col("ended_utc"))).alias("last_successful_run_utc")))
    latest_upload = Window.partitionBy("server_id").orderBy(F.col("uploaded_utc").desc_nulls_last())
    latest_processed = Window.partitionBy("server_id").orderBy(F.col("processed_utc").desc_nulls_last())
    registry_latest = (registry.where(F.col("server_id").isNotNull()).withColumn("_rn", F.row_number().over(latest_upload)).where("_rn = 1")
                       .select("server_id", F.col("server_name").alias("r_server_name"), F.col("environment").alias("r_environment"),
                               "cluster_id", "cluster_name", "gateway_id", "gateway_name",
                               F.col("agent_version").alias("r_agent_version"), F.col("agent_instance_id").alias("r_agent_instance_id")))
    registry_stats = (registry.where(F.col("server_id").isNotNull()).groupBy("server_id")
                      .agg(F.max("uploaded_utc").alias("last_upload_utc"), F.max("processed_utc").alias("last_processed_utc"),
                           F.min("first_seen_utc").alias("r_first_seen_utc")))
    last_file = (registry.where(F.col("server_id").isNotNull() & F.col("processed_utc").isNotNull())
                 .withColumn("_rn", F.row_number().over(latest_processed)).where("_rn = 1")
                 .select("server_id", F.col("source_file_name").alias("last_processed_file")))
    server_ids = (run_latest.select("server_id").union(registry_latest.select("server_id")).distinct())
    servers_df = (server_ids.join(run_latest, "server_id", "left").join(run_stats, "server_id", "left")
                  .join(registry_latest, "server_id", "left").join(registry_stats, "server_id", "left")
                  .join(last_file, "server_id", "left")
                  .select("server_id", F.coalesce("server_name", "r_server_name").alias("server_name"), "server_fqdn",
                          F.coalesce("environment", "r_environment").alias("environment"), "cluster_id", "cluster_name",
                          "gateway_id", "gateway_name",
                          F.coalesce("agent_instance_id", "r_agent_instance_id").alias("agent_instance_id"),
                          F.coalesce("agent_version", "r_agent_version").alias("agent_version"), "time_zone_id",
                          "utc_offset_minutes", F.least("first_seen_utc", "r_first_seen_utc").alias("first_seen_utc"),
                          "last_run_utc", "last_run_status", "last_successful_run_utc", "last_upload_utc",
                          "last_processed_utc", "last_processed_file",
                          F.lit(int(gold_cfg["expectedUploadIntervalMinutes"])).alias("expected_interval_minutes"),
                          F.lit(int(gold_cfg["lateAfterMinutes"])).alias("late_after_minutes"),
                          F.lit(int(gold_cfg["missingAfterMinutes"])).alias("missing_after_minutes")))
    # Decommissioned agents listed in gold.retiredServers (server id or name) no longer appear as Missing.
    retired_servers = sorted({str(value).strip().lower() for value in gold_cfg.get("retiredServers") or [] if str(value).strip()})
    if retired_servers:
        servers_df = servers_df.where(
            ~(F.coalesce(F.lower(F.col("server_id")), F.lit("")).isin(retired_servers)
              | F.coalesce(F.lower(F.col("server_name")), F.lit("")).isin(retired_servers)))
        run.details["retired_servers"] = len(retired_servers)
    overwrite_table(cap_strings(servers_df), "gold.ingestion_servers")

    # --- Gateways dimension -----------------------------------------------------------------------------------------
    fact_ids = None
    for table in ("gold.logs", "gold.queries", "gold.mashup_logs", "gold.system_counters", "gold.mashup_container_profile",
                  "gold.logs_artifact_trace"):
        ids = spark.table(table).select("gateway_id")
        fact_ids = ids if fact_ids is None else fact_ids.union(ids)
    metadata = spark.table("silver.gateway_metadata").where(F.col("gateway_id").isNotNull())
    latest_metadata = Window.partitionBy("gateway_id").orderBy(
        F.coalesce("collected_utc", "snapshot_utc").desc_nulls_last(), (F.col("metadata_source") == "agent-metadata").desc())
    meta = (metadata.withColumn("_rn", F.row_number().over(latest_metadata)).where("_rn = 1")
            .select("gateway_id", F.col("gateway_name").alias("m_gateway_name"), F.col("cluster_name").alias("m_cluster_name"),
                    F.col("cluster_id").alias("m_cluster_id"), "version", F.col("server_name").alias("m_server_name"),
                    "metadata_server_id", "number_of_cores", "memory_mb", "memory_reported", "os_architecture", "os_version",
                    "metadata_agent_version", F.coalesce("collected_utc", "snapshot_utc").alias("m_seen_utc")))
    members = spark.table("silver.gateway_cluster_members")
    latest_member = Window.partitionBy("gateway_id").orderBy(F.col("snapshot_utc").desc_nulls_last())
    clusters = (members.withColumn("_rn", F.row_number().over(latest_member)).where("_rn = 1")
                .select("gateway_id", F.col("cluster_name").alias("c_cluster_name"), F.col("cluster_id").alias("c_cluster_id")))
    reg_latest_w = Window.partitionBy("gateway_id").orderBy(F.col("uploaded_utc").desc_nulls_last())
    reg = (registry.where(F.col("gateway_id").isNotNull()).withColumn("_rn", F.row_number().over(reg_latest_w)).where("_rn = 1")
           .select("gateway_id", F.col("server_name").alias("r_server_name"), F.col("server_id").alias("r_server_id"),
                   F.col("environment").alias("r_environment"), F.col("cluster_id").alias("r_cluster_id"),
                   F.col("cluster_name").alias("r_cluster_name"), F.col("gateway_name").alias("r_gateway_name"),
                   F.col("agent_version").alias("r_agent_version")))
    reg_stats = (registry.where(F.col("gateway_id").isNotNull()).groupBy("gateway_id")
                 .agg(F.min("uploaded_utc").alias("r_first_seen"), F.max("uploaded_utc").alias("r_last_seen")))
    override_rows = [{"gateway_id": o["gatewayId"], "o_gateway_name": o.get("gatewayName"),
                      "o_cluster_name": o.get("clusterName"), "o_cluster_id": o.get("clusterId"),
                      "o_environment": o.get("environment"), "o_cores": o.get("numberOfCores")} for o in load_gateway_overrides()]
    override_schema = T.StructType([T.StructField(n, T.LongType() if n == "o_cores" else T.StringType())
                                    for n in ("gateway_id", "o_gateway_name", "o_cluster_name", "o_cluster_id", "o_environment", "o_cores")])
    overrides_df = spark.createDataFrame([tuple(r[f.name] for f in override_schema.fields) for r in override_rows], override_schema)
    all_ids = (fact_ids.union(meta.select("gateway_id")).union(clusters.select("gateway_id")).union(reg.select("gateway_id"))
               .union(overrides_df.select("gateway_id")).where(F.col("gateway_id").isNotNull()).select(F.lower("gateway_id").alias("gateway_id"))
               .distinct())
    inactive_after = F.lit(now - timedelta(days=int(gold_cfg["inactiveAfterDays"])))
    gateways_df = (all_ids.join(meta, "gateway_id", "left").join(clusters, "gateway_id", "left").join(reg, "gateway_id", "left")
                   .join(reg_stats, "gateway_id", "left").join(overrides_df, "gateway_id", "left")
                   .withColumn("gateway_name", F.coalesce("o_gateway_name", "m_gateway_name", "r_gateway_name", "gateway_id"))
                   .withColumn("server_id", F.coalesce("r_server_id", "metadata_server_id"))
                   .withColumn("last_seen_utc", F.greatest("r_last_seen", "m_seen_utc"))
                   .select("gateway_id", "gateway_name",
                           F.coalesce("o_cluster_name", "c_cluster_name", "m_cluster_name", "r_cluster_name", "gateway_name").alias("cluster_name"),
                           F.coalesce("m_server_name", "r_server_name").alias("server_name"), "version",
                           F.coalesce("o_cores", "number_of_cores").alias("number_of_cores"),
                           F.coalesce("memory_mb", "memory_reported").alias("memory"), "os_architecture", "os_version",
                           F.coalesce("o_cluster_id", "m_cluster_id", "r_cluster_id", "c_cluster_id").alias("cluster_id"),
                           F.coalesce("o_environment", "r_environment").alias("environment"), "server_id",
                           F.when(F.col("server_id").isNotNull(),
                                  F.substring(F.sha2(F.concat_ws("|", "server_id", "gateway_id"), 256), 1, 16)).alias("installation_id"),
                           F.coalesce("r_agent_version", "metadata_agent_version").alias("agent_version"),
                           F.coalesce("r_first_seen", "m_seen_utc").alias("first_seen_utc"), "last_seen_utc",
                           F.when(F.col("last_seen_utc") >= inactive_after, "Active").otherwise("Inactive").alias("status")))
    overwrite_table(cap_strings(gateways_df), "gold.gateways")

    # --- Calendar and Time --------------------------------------------------------------------------------------------
    log_dates = set()
    for table, column in (("gold.logs", "date"), ("gold.queries", "start_date"), ("gold.system_counters", "date")):
        log_dates |= {r[0] for r in spark.table(table).select(column).distinct().collect() if r[0] is not None}
    other_dates = set()
    for table, column in (("gold.mashup_logs", "date"), ("gold.ingestion_uploads", "upload_date"),
                          ("gold.ingestion_agent_runs", "run_date"), ("gold.ingestion_processing_runs", "run_date"),
                          ("gold.ingestion_issues", "detected_date"), ("gold.requests", "date")):
        other_dates |= {r[0] for r in spark.table(table).select(column).distinct().collect() if r[0] is not None}
    calendar_start, calendar_end = calendar_range(today, log_dates | other_dates, int(gold_cfg["calendarFutureYears"]))
    overwrite_table(to_df(build_calendar_rows(calendar_start, calendar_end, today, log_dates), "gold.calendar"), "gold.calendar")
    overwrite_table(to_df(build_time_rows(), "gold.time_of_day"), "gold.time_of_day")

    set_watermark("gold", silver_high_watermark or None, run.run_id)
    written["calendar"] = [calendar_start.isoformat(), calendar_end.isoformat()]
    run.details["written"] = written

    # --- Optional explicit reframe of the Direct Lake model -----------------------------------------------------------
    if reframe:
        try:
            import sempy.fabric as fabric  # Semantic Link, preinstalled in Fabric Spark runtimes
            fabric.refresh_dataset(dataset=model_name, refresh_type="full")
            run.details["reframe"] = f"requested for '{model_name}'"
        except Exception as exc:
            run.details["reframe"] = f"WARNING reframe failed: {exc}"
            print(f"[gwmon] WARNING reframe of '{model_name}' failed: {exc}")
    gold_summary = run.summary()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

exit_notebook({"setup": setup_summary, "bronze": bronze_summary, "silver": silver_summary, "gold": gold_summary})

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# MARKDOWN ********************

# # nb_gwmon_maintenance — retention, compaction and validation
# 
# Scheduled by the setup notebook to run once a day. Each run:
# 
# 1. **Maintenance** — applies the retention settings of `processing.json` to landing files and tables, removes
#    staging leftovers and orphan files, then runs `OPTIMIZE` (V-Order on Gold) and `VACUUM`.
# 2. **Validation** — checks unique keys, referential integrity, Direct Lake guardrails, Silver/Gold reconciliation
#    and agent freshness, and records the result in `ops.processing_runs`.
# 
# Set `dry_run = True` to list what would be deleted without deleting anything.

# PARAMETERS CELL ********************

# Maintenance: list what would be deleted, without deleting or compacting anything
dry_run = False
skip_optimize = False
skip_vacuum = False
# Validation: fail the run when a check fails (also processing.json validation.failOnError)
fail_on_error = False

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

# ## 1. Maintenance — retention, compaction, cleanup
# 
# * Deletes landing folders older than the configured retention (`raw`, `manifests`, `telemetry`), stale staging
#   uploads and old quarantine folders.
# * Flags **orphan** raw files (uploaded but never committed by a manifest) in `ops.quarantined_files`.
# * Applies table retention (Bronze by ingestion date, Silver by event month, ops by date). Gold retention is
#   enforced by the Gold notebook (window).
# * Runs `OPTIMIZE` (with V-Order on Gold) and `VACUUM`.
# 
# `dry_run = True` only reports what would be deleted.

# CELL ********************

configure_spark("gold")
cfg = load_config()
retention = cfg["retention"]
maintenance = cfg["maintenance"]
spark = get_spark()
now = utc_now()
today = now.date()
dry = str(dry_run).lower() == "true"
landing_root = cfg["landing"]["root"]
deleted: List[str] = []
errors: List[str] = []


def remove(relative: str) -> None:
    if dry:
        deleted.append(f"(dry-run) {relative}")
        return
    try:
        nbutils().fs.rm(relative, True)
        deleted.append(relative)
    except Exception as exc:
        errors.append(f"rm {relative}: {exc}")


def relative_of(full_path: str) -> str:
    return os.path.relpath(full_path, LAKEHOUSE_MOUNT).replace(os.sep, "/")


def expire_partitioned_days(base_relative: str, keep_days: int) -> int:
    """Delete .../year=YYYY/month=MM/day=DD folders older than ``keep_days`` anywhere below ``base_relative``."""
    cutoff = today - timedelta(days=keep_days)
    base = mount_path(base_relative)
    removed = 0
    if not os.path.isdir(base):
        return 0
    for dirpath, dirnames, _files in os.walk(base):
        name = os.path.basename(dirpath)
        if name.startswith("month=") and os.path.basename(os.path.dirname(dirpath)).startswith("year="):
            year = int(os.path.basename(os.path.dirname(dirpath)).split("=")[1])
            month = int(name.split("=")[1])
            for day_dir in list(dirnames):
                if not day_dir.startswith("day="):
                    continue
                try:
                    folder_date = date(year, month, int(day_dir.split("=")[1]))
                except ValueError:
                    continue
                if folder_date < cutoff:
                    remove(relative_of(os.path.join(dirpath, day_dir)))
                    removed += 1
            dirnames[:] = []
    return removed


def expire_quarantine(keep_days: int) -> int:
    cutoff = today - timedelta(days=keep_days)
    base = mount_path(QUARANTINE_ROOT)
    removed = 0
    if not os.path.isdir(base):
        return 0
    for year in os.listdir(base):
        for month in os.listdir(os.path.join(base, year)) if year.isdigit() else []:
            for day in os.listdir(os.path.join(base, year, month)) if month.isdigit() else []:
                try:
                    folder_date = date(int(year), int(month), int(day))
                except ValueError:
                    continue
                if folder_date < cutoff:
                    remove(relative_of(os.path.join(base, year, month, day)))
                    removed += 1
    return removed


def expire_staging(keep_days: int) -> int:
    base = mount_path(f"{landing_root}/_staging")
    limit = (now - timedelta(days=keep_days)).timestamp()
    removed = 0
    if not os.path.isdir(base):
        return 0
    for dirpath, _dirs, files in os.walk(base):
        for name in files:
            full = os.path.join(dirpath, name)
            try:
                if os.path.getmtime(full) < limit:
                    remove(relative_of(full))
                    removed += 1
            except OSError as exc:
                errors.append(f"stat {full}: {exc}")
    return removed


def find_orphans(scan_days: int, older_than_hours: int) -> List[Dict[str, Any]]:
    """Raw files in recent day folders that no manifest references (failed or interrupted agent commits)."""
    registered = {r["raw_path"] for r in spark.sql(
        f"SELECT raw_path FROM ops.segment_registry WHERE first_seen_utc >= current_timestamp() - INTERVAL {scan_days + 3} DAYS"
    ).collect()}
    threshold = (now - timedelta(hours=older_than_hours)).timestamp()
    recent_days = {(today - timedelta(days=d)) for d in range(scan_days + 1)}
    base = mount_path(f"{landing_root}/raw")
    orphans = []
    if not os.path.isdir(base):
        return orphans
    for dirpath, dirnames, files in os.walk(base):
        name = os.path.basename(dirpath)
        if not name.startswith("day="):
            continue
        dirnames[:] = []
        try:
            parent = os.path.dirname(dirpath)
            folder_date = date(int(os.path.basename(os.path.dirname(parent)).split("=")[1]),
                               int(os.path.basename(parent).split("=")[1]), int(name.split("=")[1]))
        except (ValueError, IndexError):
            continue
        if folder_date not in recent_days:
            continue
        for file_name in files:
            full = os.path.join(dirpath, file_name)
            relative = relative_of(full)
            if relative in registered:
                continue
            try:
                if os.path.getmtime(full) > threshold:
                    continue
            except OSError:
                continue
            orphans.append({
                "quarantine_id": sha256_hex(relative, "orphan-no-manifest"), "segment_id": None,
                "original_path": relative, "quarantine_path": None, "reason": "orphan-no-manifest",
                "details": "raw file not referenced by any committed manifest (left in place, removed by raw retention)",
                "detected_utc": now, "batch_id": None, "server_name": None, "server_id": None, "gateway_id": None,
                "log_type": next((p.split("=", 1)[1] for p in relative.split("/") if p.startswith("log-type=")), None),
            })
    return orphans

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

with ProcessingRun("maintenance", "nb_gwmon_maintenance",
                   parameters={"dry_run": dry, "skip_optimize": skip_optimize, "skip_vacuum": skip_vacuum}) as run:
    # --- files ---------------------------------------------------------------------------------------------------
    orphans = find_orphans(scan_days=3, older_than_hours=int(cfg["landing"]["orphanAfterHours"]))
    if orphans and not dry:
        merge_insert_only(to_df(orphans, "ops.quarantined_files"), "ops.quarantined_files", ["quarantine_id"])
    run.details["orphans"] = len(orphans)
    run.details["raw_days_removed"] = expire_partitioned_days(f"{landing_root}/raw", int(retention["rawDays"]))
    run.details["manifest_days_removed"] = expire_partitioned_days(f"{landing_root}/manifests", int(retention["manifestDays"]))
    run.details["telemetry_days_removed"] = expire_partitioned_days(f"{landing_root}/telemetry", int(retention["telemetryDays"]))
    run.details["staging_files_removed"] = expire_staging(int(retention["stagingDays"]))
    run.details["quarantine_days_removed"] = expire_quarantine(int(retention["quarantineDays"]))

    # --- tables --------------------------------------------------------------------------------------------------
    silver_cutoff = event_month_of(today - timedelta(days=int(retention["silverDays"])))
    ops_days = int(retention["opsDays"])
    statements = [f"DELETE FROM bronze.gateway_records WHERE ingest_date < date_sub(current_date(), {int(retention['bronzeDays'])})"]
    for key, table in TABLES.items():
        if table["layer"] == "silver" and "event_month" in table["partition_by"]:
            statements.append(f"DELETE FROM {key} WHERE event_month < {silver_cutoff}")
    for key, column in (("ops.segment_registry", "first_seen_utc"), ("ops.manifest_registry", "registered_utc"),
                        ("ops.agent_runs", "started_utc"), ("ops.processing_runs", "started_utc"),
                        ("ops.rejected_records", "detected_utc"), ("ops.quarantined_files", "detected_utc")):
        statements.append(f"DELETE FROM {key} WHERE {column} < current_timestamp() - INTERVAL {ops_days} DAYS")
    for statement in statements:
        if dry:
            deleted.append(f"(dry-run) {statement}")
            continue
        try:
            spark.sql(statement)
        except Exception as exc:
            errors.append(f"{statement}: {exc}")

    # --- OPTIMIZE / VACUUM ---------------------------------------------------------------------------------------------
    optimized, vacuumed = [], []
    recent_month = event_month_of(today - timedelta(days=int(maintenance["recentPartitionDays"])))
    recent_date = (today - timedelta(days=int(maintenance["recentPartitionDays"]))).isoformat()
    if not dry and not str(skip_optimize).lower() == "true":
        for key, table in TABLES.items():
            if table["layer"] not in maintenance["optimizeLayers"]:
                continue
            predicate = ""
            if maintenance.get("optimizeRecentPartitionsOnly"):
                if "event_month" in table["partition_by"]:
                    predicate = f" WHERE event_month >= {recent_month}"
                elif "ingest_date" in table["partition_by"]:
                    predicate = f" WHERE ingest_date >= DATE'{recent_date}'"
            statement = f"OPTIMIZE {key}{predicate}" + (" VORDER" if table["layer"] == "gold" else "")
            try:
                spark.sql(statement)
                optimized.append(key)
            except Exception as exc:
                if table["layer"] == "gold":
                    try:
                        spark.sql(f"OPTIMIZE {key}{predicate}")
                        optimized.append(f"{key} (without VORDER)")
                        continue
                    except Exception as inner:
                        exc = inner
                errors.append(f"{statement}: {exc}")
    if not dry and not str(skip_vacuum).lower() == "true":
        hours = max(168, int(retention["vacuumHours"]))
        for key, table in TABLES.items():
            if table["layer"] not in maintenance["vacuumLayers"]:
                continue
            try:
                spark.sql(f"VACUUM {key} RETAIN {hours} HOURS")
                vacuumed.append(key)
            except Exception as exc:
                errors.append(f"VACUUM {key}: {exc}")

    run.details.update({"deleted": deleted[:500], "deleted_count": len(deleted), "optimized": optimized,
                        "vacuumed": vacuumed, "errors": errors[:100]})
    if errors:
        print("[gwmon] maintenance completed with errors:\n" + "\n".join(errors[:50]))
    maintenance_summary = run.summary()

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# MARKDOWN ********************

# ## 2. Validation — data quality and Direct Lake readiness
# 
# | Check | Severity |
# |---|---|
# | One-side keys unique (case-insensitive, as compared by Direct Lake) | Fail |
# | Gold Parquet file count ≤ `validation.maxParquetFilesPerTable` (Direct Lake guardrail) | Fail |
# | Gold strings ≤ 32,000 characters, no NaN doubles | Fail |
# | Facts reference existing gateways / dates / times | Warn |
# | Silver ↔ Gold row reconciliation for logs inside the window | Warn |
# | Every known server sent telemetry within `validation.freshnessMinutes` | Warn |
# 
# The exit value is a JSON document used by the acceptance tests. With `fail_on_error = True` the notebook fails
# when any check fails.

# CELL ********************

configure_spark("gold")
cfg = load_config()
spark = get_spark()
checks: List[Dict[str, Any]] = []
strict = str(fail_on_error).lower() == "true" or bool(cfg["validation"].get("failOnError"))
window_month = event_month_of(utc_now().date() - timedelta(days=int(cfg["gold"]["windowDays"])))


def record(check: str, table: str, status: str, detail: Any) -> None:
    checks.append({"check": check, "table": table, "status": status, "detail": detail})
    print(f"[{status}] {check} {table}: {detail}")


UNIQUE_KEYS = {
    "gold.gateways": "gateway_id", "gold.calendar": "date", "gold.time_of_day": "time_id",
    "gold.requests": "request_id", "gold.queries": "query_tracking_id", "gold.ingestion_servers": "server_id",
}
for table, column in UNIQUE_KEYS.items():
    row = spark.sql(
        f"SELECT count(*) AS n, count(DISTINCT lower(cast({column} AS STRING))) AS d, "
        f"sum(CASE WHEN {column} IS NULL THEN 1 ELSE 0 END) AS nulls FROM {table}"
    ).first()
    duplicates = (int(row["n"]) - int(row["nulls"] or 0)) - int(row["d"])
    status = "Pass" if duplicates == 0 and not row["nulls"] else "Fail"
    record("unique-key", table, status, {"rows": row["n"], "distinct": row["d"], "nulls": row["nulls"], "duplicates": duplicates})

max_files = int(cfg["validation"]["maxParquetFilesPerTable"])
for key, table in TABLES.items():
    if table["layer"] != "gold":
        continue
    detail = spark.sql(f"DESCRIBE DETAIL {key}").first()
    files = int(detail["numFiles"] or 0)
    record("parquet-files", key, "Pass" if files <= max_files else "Fail", {"numFiles": files, "limit": max_files})
    string_columns = [c["name"] for c in table["columns"] if c["type"] == "string"]
    double_columns = [c["name"] for c in table["columns"] if c["type"] == "double"]
    if string_columns or double_columns:
        expressions = [f"max(length(`{c}`)) AS `len_{c}`" for c in string_columns]
        expressions += [f"sum(CASE WHEN isnan(`{c}`) THEN 1 ELSE 0 END) AS `nan_{c}`" for c in double_columns]
        stats = spark.sql(f"SELECT {', '.join(expressions)} FROM {key}").first().asDict()
        too_long = {k[4:]: v for k, v in stats.items() if k.startswith("len_") and v and v > DIRECT_LAKE_MAX_STRING}
        nans = {k[4:]: v for k, v in stats.items() if k.startswith("nan_") and v}
        record("direct-lake-values", key, "Fail" if (too_long or nans) else "Pass", {"too_long": too_long, "nan": nans})

for fact in ("gold.logs", "gold.queries", "gold.mashup_logs", "gold.system_counters", "gold.mashup_container_profile"):
    orphans = spark.sql(
        f"SELECT count(*) AS n FROM {fact} f LEFT ANTI JOIN gold.gateways g ON lower(f.gateway_id) = lower(g.gateway_id) "
        "WHERE f.gateway_id IS NOT NULL"
    ).first()["n"]
    record("referential-gateway", fact, "Pass" if orphans == 0 else "Warn", {"rows_without_gateway": orphans})
for fact, column in (("gold.logs", "date"), ("gold.queries", "start_date"), ("gold.mashup_logs", "date"),
                     ("gold.system_counters", "date"), ("gold.ingestion_uploads", "upload_date")):
    orphans = spark.sql(
        f"SELECT count(*) AS n FROM {fact} f LEFT ANTI JOIN gold.calendar c ON f.{column} = c.date WHERE f.{column} IS NOT NULL"
    ).first()["n"]
    record("referential-calendar", fact, "Pass" if orphans == 0 else "Warn", {"rows_without_date": orphans})

log_types_sql = ", ".join(f"'{t}'" for t in cfg["gold"]["logTypes"])
reconciliation = spark.sql(
    f"""SELECT s.event_month, s.n AS silver_rows, coalesce(g.n, 0) AS gold_rows
        FROM (SELECT event_month, count(*) AS n FROM silver.gateway_logs
              WHERE log_type IN ({log_types_sql}) AND event_month >= {window_month} GROUP BY event_month) s
        LEFT JOIN (SELECT event_month, count(*) AS n FROM gold.logs GROUP BY event_month) g ON s.event_month = g.event_month"""
).collect()
mismatches = [r.asDict() for r in reconciliation if r["silver_rows"] != r["gold_rows"]]
include_filter = bool(cfg["gold"].get("gatewayInclude"))
record("reconciliation-logs", "gold.logs", "Pass" if not mismatches or include_filter else "Warn",
       {"months": len(reconciliation), "mismatches": mismatches[:24], "gateway_filter_active": include_filter})

freshness = int(cfg["validation"]["freshnessMinutes"])
stale = spark.sql(
    f"SELECT server_name, last_run_utc FROM gold.ingestion_servers "
    f"WHERE last_run_utc IS NULL OR last_run_utc < current_timestamp() - INTERVAL {freshness} MINUTES"
).collect()
record("freshness", "gold.ingestion_servers", "Pass" if not stale else "Warn",
       {"stale_servers": [f"{r['server_name']} ({r['last_run_utc']})" for r in stale][:50]})

summary = {
    "status": "Fail" if any(c["status"] == "Fail" for c in checks) else ("Warn" if any(c["status"] == "Warn" for c in checks) else "Pass"),
    "failed": sum(1 for c in checks if c["status"] == "Fail"),
    "warnings": sum(1 for c in checks if c["status"] == "Warn"),
    "checks": checks,
}
with ProcessingRun("validate", "nb_gwmon_maintenance", parameters={"fail_on_error": strict}) as run:
    run.details = {"status": summary["status"], "failed": summary["failed"], "warnings": summary["warnings"]}
    run.metrics["rows_read"] = len(checks)
    if strict and summary["failed"]:
        raise AssertionError(f"{summary['failed']} validation check(s) failed: "
                             + "; ".join(f"{c['check']} {c['table']}" for c in checks if c["status"] == "Fail"))

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

exit_notebook({"maintenance": maintenance_summary, "validation": summary})

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# Fabric notebook source

# METADATA ********************

# META {
# META   "kernel_info": {
# META     "name": "synapse_pyspark"
# META   },
# META   "dependencies": {}
# META }

# MARKDOWN ********************

# # nb_gwmon_lib — ODGO shared library
# 
# Loaded by every `nb_gwmon_*` notebook with `%run nb_gwmon_lib`. Contains:
# 
# 1. constants and the processing configuration loader;
# 2. pure-Python parsers and normalizers for gateway logs (they don't need Spark, so they can be tested locally);
# 3. calendar and time-of-day builders;
# 4. table contracts — the single source of truth for every Delta table, the documentation and the semantic-model mapping;
# 5. Spark/Delta helpers (only used inside Fabric).
# 
# Portions of the parsing rules are derived from https://github.com/RuiRomano/pbigtwmonitor (MIT, Copyright (c) 2022 Rui Romano).

# CELL ********************

from __future__ import annotations

import base64
import binascii
import copy
import csv
import hashlib
import io
import json
import os
import re
import uuid
from datetime import date, datetime, timedelta, timezone
from typing import Any, Dict, Iterable, Iterator, List, Optional, Sequence, Tuple

GWMON_LIB_VERSION = "1.0.0"
FILES_ROOT = "Files/gateway-monitor"
LAKEHOUSE_MOUNT = "/lakehouse/default"
CONFIG_PATH = f"{FILES_ROOT}/config/processing.json"
OVERRIDES_PATH = f"{FILES_ROOT}/config/gateway-overrides.json"
QUARANTINE_ROOT = f"{FILES_ROOT}/processing/quarantine"
SCHEMAS = ("bronze", "silver", "gold", "ops")

# Power BI represents a time of day as a date/time on 1899-12-30.
TIME_EPOCH = datetime(1899, 12, 30)
EMPTY_GUID = "00000000-0000-0000-0000-000000000000"

# log-type → record format, upload mode and target Silver table.
LOG_TYPES: Dict[str, Dict[str, Any]] = {
    "gateway-info": {"format": "trace", "mode": "incremental", "silver": "gateway_logs"},
    "gateway-errors": {"format": "trace", "mode": "incremental", "silver": "gateway_logs"},
    "gateway-network": {"format": "trace", "mode": "incremental", "silver": "gateway_logs"},
    "mashup": {"format": "jsonl", "mode": "incremental", "silver": "mashup_logs"},
    "mashup-container-profiles": {"format": "profile", "mode": "snapshot", "silver": "mashup_container_profiles"},
    "query-start-report": {"format": "csv", "mode": "incremental", "silver": "query_starts"},
    "query-execution-report": {"format": "csv", "mode": "incremental", "silver": "query_executions"},
    "query-execution-aggregation-report": {"format": "csv", "mode": "incremental", "silver": "query_aggregations"},
    "system-counter-aggregation-report": {"format": "csv", "mode": "incremental", "silver": "system_counters"},
    "gateway-properties": {"format": "json", "mode": "snapshot", "silver": "gateway_metadata"},
    "gateway-clusters": {"format": "json", "mode": "snapshot", "silver": "gateway_cluster_members"},
    "gateway-configuration": {"format": "json", "mode": "snapshot", "silver": None},
    "agent-metadata": {"format": "json", "mode": "snapshot", "silver": "gateway_metadata"},
}
TRACE_LOG_TYPES = ("gateway-info", "gateway-errors", "gateway-network")
SNAPSHOT_FORMATS = ("profile", "json")

# Header lines written by the .NET trace listener; skipped exactly like the original fnReadLogFile.
TRACE_HEADER_PREFIXES = ("Starting trace on", "Version: ", "UserDomainName:", "UserName:", "MachineName:")

GUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
DATETIME_TEXT_RE = re.compile(r"^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}")
PARTITION_VALUE_RE = re.compile(r"[^a-z0-9._-]+")

# Known CSV columns per report (names normalized with normalize_column_name).
CSV_KNOWN_COLUMNS: Dict[str, Tuple[str, ...]] = {
    "query-start-report": (
        "GatewayObjectId", "RequestId", "DataSource", "QueryTrackingId", "QueryExecutionStartTimeUTC",
        "QueryType", "QueryText", "EvaluationContext",
    ),
    "query-execution-report": (
        "GatewayObjectId", "RequestId", "DataSource", "QueryTrackingId", "QueryExecutionEndTimeUTC",
        "QueryExecutionDuration(ms)", "QueryType", "DataReadingAndSerializationDuration(ms)",
        "SpoolingDiskWritingDuration(ms)", "SpoolingDiskReadingDuration(ms)", "SpoolingTotalDataSize(byte)",
        "DataProcessingEndTimeUTC", "DataProcessingDuration(ms)", "Success", "ErrorMessage",
    ),
    "query-execution-aggregation-report": (
        "GatewayObjectId", "AggregationStartTimeUTC", "AggregationEndTimeUTC", "DataSource", "Success",
        "AverageQueryExecutionDuration(ms)", "MaxQueryExecutionDuration(ms)", "MinQueryExecutionDuration(ms)",
        "QueryType", "AverageDataProcessingDuration(ms)", "MaxDataProcessingDuration(ms)",
        "MinDataProcessingDuration(ms)", "Count",
    ),
    "system-counter-aggregation-report": (
        "GatewayObjectId", "AggregationStartTimeUTC", "AggregationEndTimeUTC", "CounterName", "Max", "Min", "Average",
    ),
}

# Columns that may contain unquoted commas (JSON or free text) and need row repair.
CSV_FREE_TEXT_COLUMNS: Dict[str, Tuple[str, ...]] = {
    "query-start-report": ("DataSource", "EvaluationContext"),
    "query-execution-report": ("DataSource", "ErrorMessage"),
    "query-execution-aggregation-report": ("DataSource",),
    "system-counter-aggregation-report": (),
}

MASHUP_KNOWN_FIELDS = (
    "Start", "Action", "ProductVersion", "ActivityId", "Process", "Pid", "Duration", "ResourceKind", "ResourcePath",
    "RowCount", "ConnectionTimeout", "Exception", "identity", "containerID", "poolCount", "runningCount",
    "pendingCount", "NonFatalError", "CommandText", "CommandTimeout", "EngineEdition", "FirewallGroup",
)

MASHUP_PROFILE_FIELDS = (
    "ContainerMaxCount", "ContainerMaxWorkingSetInMB", "ContainerMaxCommitInMB", "ContainerTimeToLiveInMinute",
    "CacheTimeToLiveInMinute", "SessionTimeToLiveInMinute", "EnableCaching", "MetadataCacheTimeToLiveInMinute",
    "MetadataCacheMaxSizeInMB", "DataCacheTimeToLiveInMinute", "DataCacheMaxSizeInMB", "MashupContainerPoolType",
)

MASHUP_POOL_TYPES = {
    1: "1-DirectQueryPool",
    2: "2-TestConnectionPool",
    3: "3-MashupAzureConnectorsCachingPool",
    4: "4-Default",
    5: "5-PowerQueryOnlineCachingPool",
}

DAY_PERIODS = (
    ((0, 0), (7, 59), "Night"),
    ((8, 0), (11, 59), "Morning"),
    ((12, 0), (17, 59), "Afternoon"),
    ((18, 0), (23, 59), "Evening"),
)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------------------------------------------

DEFAULT_CONFIG: Dict[str, Any] = {
    "schemaVersion": "1.0",
    "landing": {
        "root": f"{FILES_ROOT}/landing",
        "manifestLookbackDays": 3,
        "maxManifestsPerRun": 5000,
        "maxSegmentAttempts": 5,
        "orphanAfterHours": 24,
    },
    "bronze": {"maxRecordChars": 1000000, "dedupLookbackDays": 7},
    "silver": {"extraColumnsMaxChars": 8000, "minEventYear": 2015, "maxFutureMinutes": 1440},
    "gold": {
        "windowDays": 180,
        "logTypes": ["gateway-errors", "gateway-info"],
        "maxLogTextLength": 1000,
        "maxQueryTextLength": 1000,
        "maxErrorTextLength": 4000,
        "gatewayInclude": [],
        "retiredServers": [],
        "inactiveAfterDays": 14,
        "expectedUploadIntervalMinutes": 15,
        # The report compares the last processed heartbeat with the current time: with nb_gwmon_ingest running every
        # 6 hours, a server is Late after 8 hours without a processed heartbeat and Missing after 24 hours.
        "lateAfterMinutes": 480,
        "missingAfterMinutes": 1440,
        "ingestionWindowDays": 30,
        "calendarFutureYears": 0,
    },
    "redaction": {
        "enabled": True,
        "rules": [
            {
                "name": "connection-string-secrets",
                "pattern": r"""(?i)\b(password|pwd|secret|accountkey|sharedaccesskey|access_token|client_secret)\s*=\s*("[^"]*"|'[^']*'|[^;\s"']*)""",
                "replacement": r"\1=***",
                "columns": ["event_text", "query_text", "error_message", "command_text", "exception", "data_source_path",
                            "resource_path"],
            },
            {
                "name": "bearer-tokens",
                "pattern": r"(?i)\bbearer\s+[A-Za-z0-9\-_\.=]{20,}",
                "replacement": "Bearer ***",
                "columns": ["event_text", "query_text", "error_message", "command_text", "exception"],
            },
        ],
    },
    "retention": {
        "rawDays": 30,
        "manifestDays": 90,
        "telemetryDays": 90,
        "stagingDays": 2,
        "bronzeDays": 30,
        "silverDays": 400,
        "opsDays": 400,
        "quarantineDays": 90,
        "vacuumHours": 168,
    },
    "maintenance": {
        "optimizeLayers": ["bronze", "silver", "gold", "ops"],
        "vacuumLayers": ["bronze", "silver", "gold", "ops"],
        "optimizeRecentPartitionsOnly": True,
        "recentPartitionDays": 45,
    },
    "semanticModel": {"name": "ODGO Model", "reframeAfterGold": True},
    "validation": {"failOnError": False, "maxParquetFilesPerTable": 1000, "freshnessMinutes": 480},
}

# Name of the semantic model before it was renamed "ODGO Model". processing.json files written by those versions still
# contain it, and the setup notebook renames that model in place.
LEGACY_SEMANTIC_MODEL_NAMES = ("Gateway Monitor",)

# Hard limit imposed by Direct Lake on string values (32,764 characters); a safety margin is kept.
DIRECT_LAKE_MAX_STRING = 32000


def deep_merge(base: Dict[str, Any], override: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Return a new dict where values of ``override`` replace those of ``base`` recursively."""
    result = copy.deepcopy(base)
    for key, value in (override or {}).items():
        if key == "$schema":
            continue
        if isinstance(value, dict) and isinstance(result.get(key), dict):
            result[key] = deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


def validate_config(cfg: Dict[str, Any]) -> List[str]:
    """Semantic validation of processing.json merged with the defaults (unknown keys are ignored)."""
    errors: List[str] = []
    gold = cfg.get("gold", {})
    for key in ("maxLogTextLength", "maxQueryTextLength", "maxErrorTextLength"):
        value = gold.get(key)
        if not isinstance(value, int) or value < 1 or value > DIRECT_LAKE_MAX_STRING:
            errors.append(f"gold.{key} must be an integer between 1 and {DIRECT_LAKE_MAX_STRING}")
    if not gold.get("logTypes") or any(t not in TRACE_LOG_TYPES for t in gold.get("logTypes", [])):
        errors.append(f"gold.logTypes must be a non-empty subset of {list(TRACE_LOG_TYPES)}")
    if not isinstance(gold.get("windowDays"), int) or gold["windowDays"] < 1:
        errors.append("gold.windowDays must be a positive integer")
    if gold.get("lateAfterMinutes", 0) >= gold.get("missingAfterMinutes", 0):
        errors.append("gold.lateAfterMinutes must be lower than gold.missingAfterMinutes")
    retention = cfg.get("retention", {})
    if retention.get("vacuumHours", 168) < 168:
        errors.append("retention.vacuumHours must be at least 168 (7 days)")
    for key, value in retention.items():
        if not isinstance(value, int) or value < 1:
            errors.append(f"retention.{key} must be a positive integer")
    landing_root = cfg.get("landing", {}).get("root", "")
    if not str(landing_root).startswith("Files/"):
        errors.append("landing.root must start with 'Files/'")
    for rule in cfg.get("redaction", {}).get("rules", []):
        try:
            re.compile(rule.get("pattern", ""))
        except re.error as exc:
            errors.append(f"redaction rule '{rule.get('name')}' has an invalid pattern: {exc}")
    return errors


def load_config(path: Optional[str] = None, overrides: Optional[Dict[str, Any]] = None,
                mount: str = LAKEHOUSE_MOUNT) -> Dict[str, Any]:
    """Load processing.json from the default lakehouse (if present), merge defaults and overrides, validate."""
    cfg = copy.deepcopy(DEFAULT_CONFIG)
    file_path = path or os.path.join(mount, CONFIG_PATH)
    if os.path.exists(file_path):
        with open(file_path, "r", encoding="utf-8-sig") as handle:
            cfg = deep_merge(cfg, json.load(handle))
    cfg = deep_merge(cfg, overrides or {})
    model = cfg.get("semanticModel")
    if isinstance(model, dict) and model.get("name") in LEGACY_SEMANTIC_MODEL_NAMES:
        model["name"] = DEFAULT_CONFIG["semanticModel"]["name"]
    problems = validate_config(cfg)
    if problems:
        raise ValueError("Invalid processing configuration: " + "; ".join(problems))
    return cfg


def load_gateway_overrides(path: Optional[str] = None, mount: str = LAKEHOUSE_MOUNT) -> List[Dict[str, Any]]:
    """Return the manual gateway metadata entries (empty list when the file does not exist)."""
    file_path = path or os.path.join(mount, OVERRIDES_PATH)
    if not os.path.exists(file_path):
        return []
    with open(file_path, "r", encoding="utf-8-sig") as handle:
        doc = json.load(handle)
    entries = []
    for item in doc.get("gateways", []):
        gateway_id = normalize_guid(item.get("gatewayId"))
        if gateway_id and gateway_id != EMPTY_GUID:
            entry = dict(item)
            entry["gatewayId"] = gateway_id
            entries.append(entry)
    return entries

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Value helpers (pure Python)
# ---------------------------------------------------------------------------------------------------------------


def sha256_hex(*parts: Any) -> str:
    """SHA-256 of the parts joined with '|' (None encoded as empty string)."""
    digest = hashlib.sha256()
    for index, part in enumerate(parts):
        if index:
            digest.update(b"|")
        if part is None:
            continue
        if isinstance(part, bytes):
            digest.update(part)
        else:
            digest.update(str(part).encode("utf-8"))
    return digest.hexdigest()


def utc_now() -> datetime:
    """Naive UTC 'now' (Spark sessions are pinned to UTC, naive values are interpreted as UTC)."""
    return datetime.now(timezone.utc).replace(tzinfo=None)


def new_batch_id(now: Optional[datetime] = None) -> str:
    """Monotonic, lexically sortable batch identifier: yyyyMMddHHmmssffffff + 4 random hex chars."""
    moment = now or utc_now()
    return moment.strftime("%Y%m%d%H%M%S%f") + uuid.uuid4().hex[:4]


def normalize_guid(value: Any) -> Optional[str]:
    """Lower-case GUID string or None when the value is not a GUID."""
    if value is None:
        return None
    text = str(value).strip().strip("{}")
    return text.lower() if GUID_RE.match(text) else None


def clean_text(value: Any) -> Optional[str]:
    """Strip a value and return None for empty strings and the literal 'null'."""
    if value is None:
        return None
    text = str(value).strip()
    if text == "" or text.lower() == "null":
        return None
    return text


def parse_utc(value: Any) -> Optional[datetime]:
    """Parse gateway timestamps into naive UTC datetimes.

    Accepts ISO-8601 with or without 'Z', 1–7 fractional digits, explicit offsets, space separators and the en-US
    format used by Power Query. '0001-01-01T00:00:00' (the .NET default) returns None, like the original model.
    """
    text = clean_text(value)
    if text is None:
        return None
    if isinstance(value, datetime):
        return value.astimezone(timezone.utc).replace(tzinfo=None) if value.tzinfo else value
    candidate = text.replace(" ", "T", 1) if re.match(r"^\d{4}-\d{2}-\d{2} \d", text) else text
    match = re.match(
        r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,7}))?)?(Z|[+-]\d{2}:?\d{2})?$", candidate
    )
    if match:
        year, month, day, hour, minute = (int(match.group(i)) for i in range(1, 6))
        second = int(match.group(6) or 0)
        fraction = (match.group(7) or "").ljust(6, "0")[:6]
        try:
            result = datetime(year, month, day, hour, minute, second, int(fraction or 0))
        except ValueError:
            return None
        zone = match.group(8)
        if zone and zone != "Z":
            sign = 1 if zone[0] == "+" else -1
            digits = zone[1:].replace(":", "")
            result = result - sign * timedelta(hours=int(digits[:2]), minutes=int(digits[2:]))
        if result.year <= 1:
            return None
        return result
    for pattern in ("%m/%d/%Y %I:%M:%S %p", "%m/%d/%Y %H:%M:%S", "%m/%d/%Y %I:%M %p", "%m/%d/%Y"):
        try:
            result = datetime.strptime(text, pattern)
            return None if result.year <= 1 else result
        except ValueError:
            continue
    return None


def format_utc(value: Optional[datetime]) -> Optional[str]:
    if value is None:
        return None
    return value.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def parse_int(value: Any) -> Optional[int]:
    text = clean_text(value)
    if text is None:
        return None
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    try:
        return int(text)
    except ValueError:
        try:
            number = float(text.replace(",", ""))
        except ValueError:
            return None
        if number != number or number in (float("inf"), float("-inf")):
            return None
        return int(number)


def parse_float(value: Any) -> Optional[float]:
    """Float or None; NaN and infinities become None (Direct Lake does not support NaN)."""
    text = clean_text(value)
    if text is None:
        return None
    try:
        number = float(value) if isinstance(value, (int, float)) and not isinstance(value, bool) else float(text)
    except (TypeError, ValueError):
        return None
    if number != number or number in (float("inf"), float("-inf")):
        return None
    return number


def parse_bool(value: Any) -> Optional[bool]:
    if isinstance(value, bool):
        return value
    text = clean_text(value)
    if text is None:
        return None
    lowered = text.lower()
    if lowered in ("true", "1", "yes", "y"):
        return True
    if lowered in ("false", "0", "no", "n"):
        return False
    return None


TIMESPAN_RE = re.compile(r"^(-)?(?:(\d+)\.)?(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d{1,7}))?$")


def parse_timespan_ms(value: Any) -> Optional[float]:
    """Convert a .NET TimeSpan string ('[d.]hh:mm:ss[.fffffff]') to milliseconds.

    Numeric values follow Power Query semantics (a number converted to a duration is a number of days).
    """
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return parse_float(float(value) * 86400000.0)
    text = clean_text(value)
    if text is None:
        return None
    match = TIMESPAN_RE.match(text)
    if not match:
        number = parse_float(text)
        return None if number is None else parse_float(number * 86400000.0)
    sign = -1.0 if match.group(1) else 1.0
    days = int(match.group(2) or 0)
    hours, minutes, seconds = int(match.group(3)), int(match.group(4)), int(match.group(5))
    fraction = match.group(6) or ""
    ticks = int(fraction.ljust(7, "0")) if fraction else 0
    total_ms = ((days * 24 + hours) * 3600 + minutes * 60 + seconds) * 1000.0 + ticks / 10000.0
    return sign * total_ms


def decode_base64_text(value: Any) -> Tuple[Optional[str], Optional[str]]:
    """Decode base64 text (QueryText). Returns (text, error)."""
    text = clean_text(value)
    if text is None:
        return None, None
    try:
        raw = base64.b64decode(text + "=" * (-len(text) % 4), validate=False)
    except (binascii.Error, ValueError) as exc:
        return None, f"invalid base64: {exc}"
    decoded, _ = decode_bytes(raw)
    return decoded, None


def decode_bytes(data: bytes) -> Tuple[str, str]:
    """Decode log bytes: BOM-aware, UTF-8 first, Windows-1252 fallback (the original used code page 1252)."""
    if data.startswith(b"\xef\xbb\xbf"):
        return data[3:].decode("utf-8", errors="replace"), "utf-8-sig"
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        return data.decode("utf-16", errors="replace"), "utf-16"
    try:
        return data.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        return data.decode("cp1252", errors="replace"), "cp1252"


def time_of_day(moment: Optional[datetime]) -> Optional[datetime]:
    """Time-of-day on Power BI's time epoch (1899-12-30), second precision (original used 'HH:mm:ss')."""
    if moment is None:
        return None
    return TIME_EPOCH.replace(hour=moment.hour, minute=moment.minute, second=moment.second)


def minute_floor(moment: Optional[datetime]) -> Optional[datetime]:
    if moment is None:
        return None
    return moment.replace(second=0, microsecond=0)


def time_id_of(moment: Optional[datetime]) -> Optional[int]:
    """'HHmm' as an integer, the key of the Time table."""
    if moment is None:
        return None
    return moment.hour * 100 + moment.minute


def event_month_of(moment: Optional[Any]) -> Optional[int]:
    if moment is None:
        return None
    return moment.year * 100 + moment.month


def truncate(value: Optional[str], length: int) -> Optional[str]:
    if value is None:
        return None
    limit = max(1, min(int(length), DIRECT_LAKE_MAX_STRING))
    return value if len(value) <= limit else value[:limit]


def sanitize_partition_value(value: Any, fallback: str = "unknown") -> str:
    """Lower-case partition value restricted to [a-z0-9._-] (same rule as the agent)."""
    text = clean_text(value)
    if text is None:
        return fallback
    cleaned = PARTITION_VALUE_RE.sub("-", text.lower()).strip("-.")
    return cleaned[:63] if cleaned else fallback


def normalize_column_name(name: Any) -> str:
    """Case/space-insensitive column key: 'QueryExecutionDuration (ms)' → 'queryexecutionduration(ms)'."""
    return re.sub(r"\s+", "", str(name or "")).lower()


def compact_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True, default=str)


class Redactor:
    """Applies the configured regex redaction rules to the named Silver text columns."""

    def __init__(self, cfg: Optional[Dict[str, Any]] = None):
        section = (cfg or {}).get("redaction", {}) if cfg else {}
        self.enabled = bool(section.get("enabled", False))
        self.rules: List[Tuple[re.Pattern, str, Tuple[str, ...]]] = []
        if self.enabled:
            for rule in section.get("rules", []):
                self.rules.append((re.compile(rule["pattern"]), rule["replacement"], tuple(rule["columns"])))

    def apply(self, column: str, value: Optional[str]) -> Optional[str]:
        if value is None or not self.enabled:
            return value
        for pattern, replacement, columns in self.rules:
            if column in columns:
                value = pattern.sub(replacement, value)
        return value

    def apply_row(self, row: Dict[str, Any]) -> Dict[str, Any]:
        if not self.enabled:
            return row
        for column in ("event_text", "query_text", "error_message", "command_text", "exception",
                       "data_source_path", "resource_path"):
            if column in row and isinstance(row[column], str):
                row[column] = self.apply(column, row[column])
        return row

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Segment parsers (Bronze) — pure Python
# ---------------------------------------------------------------------------------------------------------------

UTF8_BOM = b"\xef\xbb\xbf"


def iter_lines_with_offsets(data: bytes) -> Iterator[Tuple[int, bytes]]:
    """Yield (byte offset, line bytes without CR/LF) for every line of ``data``."""
    start = 0
    length = len(data)
    while start < length:
        end = data.find(b"\n", start)
        if end == -1:
            yield start, data[start:].rstrip(b"\r")
            return
        yield start, data[start:end].rstrip(b"\r")
        start = end + 1


def _decode_line(raw: bytes) -> str:
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1252", errors="replace")


def text_lines(data: bytes) -> Tuple[List[Tuple[Optional[int], str]], str]:
    """Split bytes into (byte offset, text) lines. UTF-16 content yields offsets of None."""
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        text = data.decode("utf-16", errors="replace")
        parts = text.split("\n")
        if parts and parts[-1] == "":
            parts.pop()
        return [(None, part.rstrip("\r")) for part in parts], "utf-16"
    lines: List[Tuple[Optional[int], str]] = []
    encoding = "utf-8"
    for offset, raw in iter_lines_with_offsets(data):
        if offset == 0 and raw.startswith(UTF8_BOM):
            raw = raw[len(UTF8_BOM):]
            encoding = "utf-8-sig"
        try:
            lines.append((offset, raw.decode("utf-8")))
        except UnicodeDecodeError:
            lines.append((offset, raw.decode("cp1252", errors="replace")))
            encoding = "cp1252"
    return lines, encoding


def split_trace_records(lines: Sequence[Tuple[Optional[int], str]]):
    """Group trace lines into records exactly like the original fnReadLogFile.

    * header lines ('Starting trace on', 'Version: ', ...) and empty lines are dropped;
    * a record starts with a line beginning with 'DM.';
    * following lines that do not start with 'DM.' are continuation lines joined with CRLF.

    Returns (records, orphans): lists of (offset, text). Orphans are continuation lines without a record start.
    """
    records: List[Tuple[Optional[int], str]] = []
    orphans: List[Tuple[Optional[int], str]] = []
    current_offset: Optional[int] = None
    current_lines: List[str] = []
    has_current = False
    for offset, line in lines:
        if line == "" or line.startswith(TRACE_HEADER_PREFIXES):
            continue
        if line.startswith("DM."):
            if has_current:
                records.append((current_offset, "\r\n".join(current_lines)))
            current_offset, current_lines, has_current = offset, [line], True
        elif has_current:
            current_lines.append(line)
        else:
            orphans.append((offset, line))
    if has_current:
        records.append((current_offset, "\r\n".join(current_lines)))
    return records, orphans


def parse_trace_record(text: str) -> Dict[str, Any]:
    """Parse one trace record into the fields produced by the original fnReadLogFile.

    Layout: '<GatewayType> <Level>: <id> : <timestamp> <...>' TAB ActivityId TAB RootActivityId TAB ActivityType
    TAB ClientActivityId TAB SourceId TAB HelperId TAB '<Hash> <EventText>'. Tabs inside the event text are kept
    (the original dropped everything after the 8th tab-separated field).
    """
    if not text or not text.startswith("DM."):
        raise ValueError("record does not start with 'DM.'")
    parts = text.split("\t", 7)
    head = parts[0].split(" ")
    gateway_type = head[0] if head else None
    level = head[1].replace(":", "") if len(head) > 1 else None
    timestamp_text = head[4] if len(head) > 4 else None
    event_utc = parse_utc(timestamp_text)
    if event_utc is None:
        raise ValueError(f"invalid or missing timestamp '{timestamp_text}'")

    def field(index: int) -> Optional[str]:
        return clean_text(parts[index]) if len(parts) > index else None

    hash_value: Optional[str] = None
    event_text: Optional[str] = None
    if len(parts) > 7:
        rest = parts[7]
        if " " in rest:
            hash_value, event_text = rest.split(" ", 1)
        else:
            hash_value, event_text = rest, None
        hash_value = clean_text(hash_value)
    return {
        "instance": clean_text(gateway_type),
        "level": clean_text(level),
        "event_utc": event_utc,
        "activity_id": field(1),
        "root_activity_id": field(2),
        "activity_type": field(3),
        "client_activity_id": field(4),
        "root_gateway_client_pipeline_id": field(5),
        "current_gateway_client_pipeline_id": field(6),
        "hash": hash_value,
        "event_text_full": event_text,
    }


def split_event_type(event_text: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """'[DM.GatewayCore] text' → ('[DM.GatewayCore]', 'text') — the 'EventType' split of the original Logs query."""
    if event_text is None:
        return None, None
    if " " in event_text:
        event_type, rest = event_text.split(" ", 1)
        return clean_text(event_type), rest
    return clean_text(event_text), None


def _assemble_csv_records(lines: Sequence[Tuple[Optional[int], str]], max_lines: int = 500):
    """Join physical lines while double quotes are unbalanced (quoted fields may contain newlines)."""
    records: List[Tuple[Optional[int], str]] = []
    buffer: List[Tuple[Optional[int], str]] = []
    quotes = 0
    for offset, line in lines:
        buffer.append((offset, line))
        quotes += line.count('"')
        if quotes % 2 == 0 or len(buffer) >= max_lines:
            records.append((buffer[0][0], "\n".join(text for _, text in buffer)))
            buffer, quotes = [], 0
    if buffer:
        records.extend(buffer)
    return records


def _column_kind(name: str) -> str:
    key = normalize_column_name(name)
    if key.endswith("utc") or key.endswith("time"):
        return "datetime"
    if key.endswith("id"):
        return "guid"
    if "(ms)" in key or "(byte)" in key or key in ("count", "max", "min", "average"):
        return "number"
    return "any"


def _matches_kind(value: str, kind: str) -> bool:
    text = value.strip()
    if kind == "guid":
        return bool(GUID_RE.match(text.strip("{}")))
    if kind == "datetime":
        return text == "" or bool(DATETIME_TEXT_RE.match(text))
    if kind == "number":
        return text == "" or parse_float(text) is not None
    return True


def repair_csv_fields(log_type: str, header: Sequence[str], fields: Sequence[str]) -> Optional[List[str]]:
    """Re-align a CSV row whose field count differs from the header.

    Rows with fewer fields are padded. Rows with more fields happen when JSON/free-text columns (DataSource,
    ErrorMessage, EvaluationContext) contain unquoted commas: the extra fields are merged back into those columns,
    using the type of the neighbouring columns (GUID, timestamp, number) as anchors.
    """
    fields = list(fields)
    if len(fields) == len(header):
        return fields
    if len(fields) < len(header):
        return fields + [""] * (len(header) - len(fields))
    normalized = [normalize_column_name(h) for h in header]
    free_columns = {normalize_column_name(c) for c in CSV_FREE_TEXT_COLUMNS.get(log_type, ())}
    free_positions = [index for index, name in enumerate(normalized) if name in free_columns]
    if not free_positions:
        return None
    result: List[str] = []
    cursor = 0
    for position_index, free_index in enumerate(free_positions):
        while len(result) < free_index:
            if cursor >= len(fields):
                return None
            result.append(fields[cursor])
            cursor += 1
        is_last_free = position_index == len(free_positions) - 1
        trailing_fixed = len(header) - free_index - 1
        if is_last_free:
            end = len(fields) - trailing_fixed
            if end <= cursor - 1:
                return None
            result.append(",".join(fields[cursor:end]))
            result.extend(fields[end:])
            cursor = len(fields)
        else:
            next_free = free_positions[position_index + 1]
            fixed_between = header[free_index + 1:next_free]
            kinds = [_column_kind(name) for name in fixed_between[:2]]
            chosen = None
            for end in range(cursor + 1, len(fields) - len(fixed_between) + 1):
                candidates = fields[end:end + len(kinds)]
                if len(candidates) == len(kinds) and all(_matches_kind(v, k) for v, k in zip(candidates, kinds)):
                    chosen = end
                    break
            if chosen is None:
                return None
            result.append(",".join(fields[cursor:chosen]))
            cursor = chosen
    return result if len(result) == len(header) else None


def parse_csv_records(lines: Sequence[Tuple[Optional[int], str]], log_type: str):
    """Return (header, rows). rows = (offset, text, fields dict or None, error or None, is_header_repeat)."""
    records = [r for r in _assemble_csv_records(lines) if r[1].strip() != ""]
    if not records:
        return [], []
    header_text = records[0][1]
    header = [h.strip().strip('"') for h in next(csv.reader([header_text]))]
    rows = []
    for offset, text in records[1:]:
        if text == header_text:
            continue
        try:
            fields = next(csv.reader(io.StringIO(text)))
        except (csv.Error, StopIteration) as exc:
            rows.append((offset, text, None, f"csv error: {exc}"))
            continue
        aligned = repair_csv_fields(log_type, header, fields)
        if aligned is None:
            rows.append((offset, text, None, f"expected {len(header)} fields, found {len(fields)}"))
            continue
        rows.append((offset, text, dict(zip(header, aligned)), None))
    return header, rows


def parse_jsonl_records(lines: Sequence[Tuple[Optional[int], str]]):
    """Return (rows, skipped). rows = (offset, text, object or None, error or None). Non-JSON lines are skipped
    like the original (which kept only lines starting with '{' and ending with '}')."""
    rows = []
    skipped = 0
    for offset, line in lines:
        stripped = line.strip()
        if not stripped:
            continue
        if not (stripped.startswith("{") and stripped.endswith("}")):
            skipped += 1
            continue
        try:
            obj = json.loads(stripped)
        except ValueError as exc:
            rows.append((offset, stripped, None, f"invalid json: {exc}"))
            continue
        if not isinstance(obj, dict):
            rows.append((offset, stripped, None, "json value is not an object"))
            continue
        rows.append((offset, stripped, obj, None))
    return rows, skipped


def parse_profile_objects(text: str) -> Tuple[List[Dict[str, Any]], Optional[str]]:
    """Extract the JSON objects of MashupContainerProfiles.log (header lines followed by concatenated objects)."""
    lines = text.splitlines()
    start = next((i for i, line in enumerate(lines) if line.strip().startswith("{")), None)
    if start is None:
        return [], None
    body = "".join(lines[start:])
    decoder = json.JSONDecoder()
    objects: List[Dict[str, Any]] = []
    position = 0
    while position < len(body):
        while position < len(body) and body[position] in " \t\r\n,[]":
            position += 1
        if position >= len(body):
            break
        try:
            obj, end = decoder.raw_decode(body, position)
        except ValueError as exc:
            return objects, f"invalid json at character {position}: {exc}"
        if isinstance(obj, dict):
            objects.append(obj)
        position = end
    return objects, None


def parse_segment(content: bytes, meta: Dict[str, Any], max_record_chars: int = 1000000):
    """Parse one uploaded segment into Bronze records.

    ``meta`` uses manifest field names (segmentId, logType, format, uploadMode, offsetStart, headerBytes, sha256,
    byteCount, gatewayId, sourceFingerprint). Returns (records, result) where result has 'status'
    (Processed | Quarantined), 'reason', counters and the detected encoding.
    """
    log_type = meta.get("logType")
    record_format = meta.get("format") or LOG_TYPES.get(log_type, {}).get("format")
    result: Dict[str, Any] = {"status": "Processed", "reason": None, "record_count": 0, "malformed_count": 0,
                              "skipped_count": 0, "encoding": None}
    expected_hash = (meta.get("sha256") or "").lower()
    if expected_hash and hashlib.sha256(content).hexdigest() != expected_hash:
        result.update(status="Quarantined", reason="checksum-mismatch")
        return [], result
    byte_count = meta.get("byteCount")
    if byte_count is not None and int(byte_count) != len(content):
        result.update(status="Quarantined", reason="size-mismatch")
        return [], result
    if log_type not in LOG_TYPES or record_format not in ("trace", "jsonl", "csv", "profile", "json"):
        result.update(status="Quarantined", reason=f"unsupported log type '{log_type}' or format '{record_format}'")
        return [], result
    if not content:
        return [], result
    if b"\x00" in content[:4096] and not (content.startswith(b"\xff\xfe") or content.startswith(b"\xfe\xff")):
        result.update(status="Quarantined", reason="binary-content")
        return [], result

    segment_id = meta.get("segmentId")
    gateway_id = meta.get("gatewayId")
    offset_start = int(meta.get("offsetStart") or 0)
    header_bytes = int(meta.get("headerBytes") or 0)
    snapshot = record_format in SNAPSHOT_FORMATS or meta.get("uploadMode") == "snapshot"
    fingerprint = meta.get("sourceFingerprint") if snapshot else None
    records: List[Dict[str, Any]] = []

    def absolute(rel: Optional[int]) -> Optional[int]:
        if rel is None:
            return None
        if snapshot:
            return rel
        return offset_start + max(0, rel - header_bytes)

    def add(rel_offset: Optional[int], text: str, fields: Optional[Dict[str, Any]], error: Optional[str]):
        index = len(records)
        stored = text if len(text) <= max_record_chars else text[:max_record_chars]
        records.append({
            "record_id": sha256_hex(segment_id, index),
            "record_key": sha256_hex(log_type, gateway_id, fingerprint, text),
            "segment_id": segment_id,
            "record_index": index,
            "record_offset": absolute(rel_offset),
            "log_type": log_type,
            "record_format": record_format,
            "record_text": stored,
            "record_fields_json": compact_json(fields) if fields is not None else None,
            "record_truncated": len(text) > max_record_chars,
            "parse_status": "malformed" if error else "ok",
            "parse_error": error,
        })

    if record_format in ("profile", "json"):
        text, encoding = decode_bytes(content)
        result["encoding"] = encoding
        if record_format == "json":
            try:
                document = json.loads(text)
                add(0, text, None, None if isinstance(document, (dict, list)) else "json root is not an object")
            except ValueError as exc:
                add(0, text, None, f"invalid json: {exc}")
        else:
            objects, error = parse_profile_objects(text)
            for obj in objects:
                add(None, compact_json(obj), None, None)
            if error:
                add(None, text[-2000:], None, error)
    else:
        lines, encoding = text_lines(content)
        result["encoding"] = encoding
        if record_format == "trace":
            trace_records, orphans = split_trace_records(lines)
            for offset, text in orphans:
                add(offset, text, None, "continuation line without record header")
            for offset, text in trace_records:
                add(offset, text, None, None)
        elif record_format == "jsonl":
            rows, skipped = parse_jsonl_records(lines)
            result["skipped_count"] = skipped
            for offset, text, _obj, error in rows:
                add(offset, text, None, error)
        else:
            _header, rows = parse_csv_records(lines, log_type)
            for offset, text, fields, error in rows:
                add(offset, text, fields, error)
    result["record_count"] = len(records)
    result["malformed_count"] = sum(1 for r in records if r["parse_status"] == "malformed")
    return records, result

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Silver normalizers — pure Python
# ---------------------------------------------------------------------------------------------------------------
# Identifier columns are lower-cased: Analysis Services (Direct Lake) compares strings case-insensitively, so keys
# that differ only by case would violate the uniqueness required on the one-side of relationships.


def lower_id(value: Any) -> Optional[str]:
    text = clean_text(value)
    if text is None:
        return None
    guid = normalize_guid(text)
    return guid if guid else text.lower()


def _split_known(fields: Dict[str, Any], known: Sequence[str]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    """Return (normalized known fields, unknown fields with original names) — unknown fields are schema drift."""
    known_keys = {normalize_column_name(k) for k in known}
    normalized: Dict[str, Any] = {}
    extras: Dict[str, Any] = {}
    for key, value in fields.items():
        nk = normalize_column_name(key)
        if nk in known_keys:
            normalized[nk] = value
        elif not str(key).startswith("_"):
            extras[key] = value
    return normalized, extras


def _check_event_time(moment: Optional[datetime], settings: Dict[str, Any], label: str) -> datetime:
    if moment is None:
        raise ValueError(f"missing {label}")
    if moment.year < settings.get("minEventYear", 2015):
        raise ValueError(f"{label} {moment.isoformat()} is before {settings.get('minEventYear', 2015)}")
    limit = utc_now() + timedelta(minutes=settings.get("maxFutureMinutes", 1440))
    if moment > limit:
        raise ValueError(f"{label} {moment.isoformat()} is in the future")
    return moment


def normalize_gateway_log(record_text: str, settings: Dict[str, Any], redactor: Optional[Redactor] = None) -> Dict[str, Any]:
    parsed = parse_trace_record(record_text)
    _check_event_time(parsed["event_utc"], settings, "event timestamp")
    event_type, event_text = split_event_type(parsed["event_text_full"])
    row = {
        "instance": parsed["instance"],
        "level": parsed["level"],
        "event_utc": parsed["event_utc"],
        "activity_id": lower_id(parsed["activity_id"]),
        "root_activity_id": lower_id(parsed["root_activity_id"]),
        "activity_type": parsed["activity_type"],
        "client_activity_id": lower_id(parsed["client_activity_id"]),
        "root_gateway_client_pipeline_id": lower_id(parsed["root_gateway_client_pipeline_id"]),
        "current_gateway_client_pipeline_id": lower_id(parsed["current_gateway_client_pipeline_id"]),
        "hash": parsed["hash"],
        "event_type": event_type,
        "event_text": event_text,
        "event_text_length": len(event_text) if event_text is not None else 0,
    }
    if redactor:
        row["event_text"] = redactor.apply("event_text", row["event_text"])
    return row


def extract_artifact_trace(event_type: Optional[str], event_text: Optional[str]) -> Optional[Dict[str, Any]]:
    """Parse '[DM.GatewayCore] EvaluationTraceContext ... Trace ids: [[Key, Value], [Key, Value]]' like the
    original LogsArtifactTrace query."""
    if event_type != "[DM.GatewayCore]" or not event_text or not event_text.startswith("EvaluationTraceContext"):
        return None
    marker = "Trace ids:"
    if marker not in event_text:
        return None
    payload = event_text.split(marker, 1)[1]
    payload = payload.replace("[[", "").replace("]]", "").strip()
    properties: Dict[str, str] = {}
    for item in payload.split("], ["):
        pieces = item.split(",")
        if len(pieces) >= 2:
            properties[pieces[0].strip()] = pieces[1].strip()
    lookup = {k.lower(): v for k, v in properties.items()}
    result = {
        "root_activity_id": lower_id(lookup.get("rootactivityid")),
        "current_activity_id": lower_id(lookup.get("currentactivityid")),
        "dataset_id": lower_id(lookup.get("datasetid")),
        "query_type": clean_text(lookup.get("querytype")),
        "sku": clean_text(lookup.get("sku")),
        "workspace_id": lower_id(lookup.get("workspaceid")),
    }
    if not result["root_activity_id"]:
        return None
    return result


def parse_datasources(data_source: Any) -> List[Tuple[str, Optional[str]]]:
    """Explode the DataSource column (JSON array of JSON strings) into distinct (kind, lower-cased path) pairs.
    Unparseable values produce ('Unknown', None), as in the original 'Queries - Datasources' query."""
    unknown = [("Unknown", None)]
    text = clean_text(data_source)
    if text is None:
        return unknown
    try:
        items = json.loads(text)
    except ValueError:
        return unknown
    if not isinstance(items, list):
        items = [items]
    pairs: List[Tuple[str, Optional[str]]] = []
    for item in items:
        element = item
        if isinstance(item, str):
            try:
                element = json.loads(item)
            except ValueError:
                element = None
        if isinstance(element, dict):
            kind = clean_text(element.get("kind")) or "Unknown"
            path = clean_text(element.get("path"))
            pair = (kind, path.lower() if path else None)
        else:
            pair = ("Unknown", None)
        if pair not in pairs:
            pairs.append(pair)
    return pairs or unknown


def normalize_query_start(fields: Dict[str, Any], fallback_gateway_id: Optional[str], settings: Dict[str, Any],
                          redactor: Optional[Redactor] = None) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    f, extras = _split_known(fields, CSV_KNOWN_COLUMNS["query-start-report"])
    start = _check_event_time(parse_utc(f.get("queryexecutionstarttimeutc")), settings, "QueryExecutionStartTimeUTC")
    tracking = lower_id(f.get("querytrackingid"))
    if not tracking:
        raise ValueError("missing QueryTrackingId")
    query_text, decode_error = decode_base64_text(f.get("querytext"))
    if decode_error:
        extras["_queryTextDecodeError"] = decode_error
    row = {
        "gateway_id": normalize_guid(f.get("gatewayobjectid")) or fallback_gateway_id,
        "request_id": lower_id(f.get("requestid")),
        "query_tracking_id": tracking,
        "query_start_utc": start,
        "query_type": clean_text(f.get("querytype")),
        "data_source": clean_text(f.get("datasource")),
        "query_text": query_text,
        "query_text_length": len(query_text) if query_text is not None else 0,
        "evaluation_context": clean_text(f.get("evaluationcontext")),
    }
    if redactor:
        row["query_text"] = redactor.apply("query_text", row["query_text"])
    return row, extras


def normalize_query_execution(fields: Dict[str, Any], settings: Dict[str, Any],
                              redactor: Optional[Redactor] = None) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    f, extras = _split_known(fields, CSV_KNOWN_COLUMNS["query-execution-report"])
    gateway_id = normalize_guid(f.get("gatewayobjectid"))
    if not gateway_id:
        raise ValueError("GatewayObjectId is not a valid GUID")
    tracking = lower_id(f.get("querytrackingid"))
    if not tracking:
        raise ValueError("missing QueryTrackingId")
    execution_end = parse_utc(f.get("queryexecutionendtimeutc"))
    processing_end = parse_utc(f.get("dataprocessingendtimeutc"))
    row = {
        "gateway_id": gateway_id,
        "request_id": lower_id(f.get("requestid")),
        "query_tracking_id": tracking,
        "data_source": clean_text(f.get("datasource")),
        "query_type": clean_text(f.get("querytype")),
        "query_execution_end_utc": execution_end,
        "query_execution_duration_ms": parse_int(f.get("queryexecutionduration(ms)")),
        "data_reading_and_serialization_duration_ms": parse_int(f.get("datareadingandserializationduration(ms)")),
        "spooling_disk_writing_duration_ms": parse_int(f.get("spoolingdiskwritingduration(ms)")),
        "spooling_disk_reading_duration_ms": parse_int(f.get("spoolingdiskreadingduration(ms)")),
        "spooling_total_data_size_bytes": parse_int(f.get("spoolingtotaldatasize(byte)")),
        "data_processing_end_utc": processing_end,
        "data_processing_duration_ms": parse_int(f.get("dataprocessingduration(ms)")),
        "success": clean_text(f.get("success")),
        "error_message": clean_text(f.get("errormessage")),
    }
    if redactor:
        row["error_message"] = redactor.apply("error_message", row["error_message"])
    return row, extras


def normalize_query_aggregation(fields: Dict[str, Any], fallback_gateway_id: Optional[str], settings: Dict[str, Any]
                                ) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    f, extras = _split_known(fields, CSV_KNOWN_COLUMNS["query-execution-aggregation-report"])
    end = _check_event_time(parse_utc(f.get("aggregationendtimeutc")), settings, "AggregationEndTimeUTC")
    row = {
        "gateway_id": normalize_guid(f.get("gatewayobjectid")) or fallback_gateway_id,
        "aggregation_start_utc": parse_utc(f.get("aggregationstarttimeutc")),
        "aggregation_end_utc": end,
        "data_source": clean_text(f.get("datasource")),
        "success": clean_text(f.get("success")),
        "average_query_execution_duration_ms": parse_float(f.get("averagequeryexecutionduration(ms)")),
        "max_query_execution_duration_ms": parse_float(f.get("maxqueryexecutionduration(ms)")),
        "min_query_execution_duration_ms": parse_float(f.get("minqueryexecutionduration(ms)")),
        "query_type": clean_text(f.get("querytype")),
        "average_data_processing_duration_ms": parse_float(f.get("averagedataprocessingduration(ms)")),
        "max_data_processing_duration_ms": parse_float(f.get("maxdataprocessingduration(ms)")),
        "min_data_processing_duration_ms": parse_float(f.get("mindataprocessingduration(ms)")),
        "query_count": parse_int(f.get("count")),
    }
    return row, extras


def normalize_system_counter(fields: Dict[str, Any], fallback_gateway_id: Optional[str], settings: Dict[str, Any]
                             ) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    f, extras = _split_known(fields, CSV_KNOWN_COLUMNS["system-counter-aggregation-report"])
    end = _check_event_time(parse_utc(f.get("aggregationendtimeutc")), settings, "AggregationEndTimeUTC")
    counter = clean_text(f.get("countername"))
    if not counter:
        raise ValueError("missing CounterName")
    row = {
        "gateway_id": normalize_guid(f.get("gatewayobjectid")) or fallback_gateway_id,
        "aggregation_start_utc": parse_utc(f.get("aggregationstarttimeutc")),
        "aggregation_end_utc": end,
        "counter_name": counter,
        "max_value": parse_float(f.get("max")),
        "min_value": parse_float(f.get("min")),
        "average_value": parse_float(f.get("average")),
    }
    return row, extras


def normalize_mashup_log(obj: Dict[str, Any], settings: Dict[str, Any], redactor: Optional[Redactor] = None
                         ) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    known = {k: v for k, v in obj.items() if k in MASHUP_KNOWN_FIELDS}
    extras = {k: v for k, v in obj.items() if k not in MASHUP_KNOWN_FIELDS}
    start = _check_event_time(parse_utc(known.get("Start")), settings, "Start")
    action = clean_text(known.get("Action"))
    action_group, action_detail = None, None
    if action is not None:
        if "/" in action:
            action_group, action_detail = action.split("/", 1)
        else:
            action_group = action
    exception = known.get("Exception")
    exception_text = None if exception is None else (exception if isinstance(exception, str) else compact_json(exception))
    row = {
        "start_utc": start,
        "action": action,
        "action_group": clean_text(action_group),
        "action_detail": clean_text(action_detail),
        "product_version": clean_text(known.get("ProductVersion")),
        "activity_id": lower_id(known.get("ActivityId")),
        "process": clean_text(known.get("Process")),
        "pid": parse_int(known.get("Pid")),
        "duration_ms": parse_timespan_ms(known.get("Duration")),
        "resource_kind": clean_text(known.get("ResourceKind")),
        "resource_path": clean_text(known.get("ResourcePath")),
        "row_count": parse_int(known.get("RowCount")),
        "connection_timeout": parse_int(known.get("ConnectionTimeout")),
        "exception": exception_text,
        "identity": clean_text(known.get("identity")) or "Default",
        "container_id": parse_int(known.get("containerID")),
        "pool_count": parse_int(known.get("poolCount")),
        "running_count": parse_int(known.get("runningCount")),
        "pending_count": parse_int(known.get("pendingCount")),
        "non_fatal_error": clean_text(known.get("NonFatalError")),
        "command_text": clean_text(known.get("CommandText")),
        "command_timeout": parse_int(known.get("CommandTimeout")),
        "engine_edition": clean_text(known.get("EngineEdition")),
        "firewall_group": clean_text(known.get("FirewallGroup")),
        "error_yn": "N" if exception is None else "Y",
    }
    if redactor:
        for column in ("exception", "command_text", "resource_path"):
            row[column] = redactor.apply(column, row[column])
    return row, extras


def mashup_pool_type_name(pool_type_id: Optional[int]) -> Optional[str]:
    if pool_type_id is None:
        return None
    return MASHUP_POOL_TYPES.get(pool_type_id, f"{pool_type_id}-OtherPool")


def normalize_mashup_profile(obj: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    extras = {k: v for k, v in obj.items() if k not in MASHUP_PROFILE_FIELDS}
    pool_type_id = parse_int(obj.get("MashupContainerPoolType"))
    row = {
        "pool_type_id": pool_type_id,
        "pool_type": mashup_pool_type_name(pool_type_id),
        "container_max_count": parse_int(obj.get("ContainerMaxCount")),
        "container_max_working_set_in_mb": parse_int(obj.get("ContainerMaxWorkingSetInMB")),
        "container_max_commit_in_mb": parse_int(obj.get("ContainerMaxCommitInMB")),
        "container_time_to_live_in_minute": parse_int(obj.get("ContainerTimeToLiveInMinute")),
        "cache_time_to_live_in_minute": parse_int(obj.get("CacheTimeToLiveInMinute")),
        "session_time_to_live_in_minute": parse_int(obj.get("SessionTimeToLiveInMinute")),
        "enable_caching": parse_bool(obj.get("EnableCaching")),
        "metadata_cache_time_to_live_in_minute": parse_int(obj.get("MetadataCacheTimeToLiveInMinute")),
        "metadata_cache_max_size_in_mb": parse_int(obj.get("MetadataCacheMaxSizeInMB")),
        "data_cache_time_to_live_in_minute": parse_int(obj.get("DataCacheTimeToLiveInMinute")),
        "data_cache_max_size_in_mb": parse_int(obj.get("DataCacheMaxSizeInMB")),
    }
    return row, extras


def _version_after_colon(value: Any) -> Optional[str]:
    """'Version: 3000.123.4' → '3000.123.4' (Text.AfterDelimiter(_, ": ", {0, RelativePosition.FromEnd}))."""
    text = clean_text(value)
    if text is None:
        return None
    return clean_text(text.rsplit(": ", 1)[-1])


def normalize_gateway_metadata(document: Any, log_type: str, fallback_gateway_id: Optional[str]) -> Dict[str, Any]:
    """agent-metadata (gwmon.agent-metadata) or GatewayProperties.txt → one gateway_metadata row."""
    if not isinstance(document, dict):
        raise ValueError("metadata document is not a JSON object")
    if log_type == "agent-metadata":
        gateway = document.get("gateway") or {}
        server = document.get("server") or {}
        agent = document.get("agent") or {}
        return {
            "metadata_source": "agent-metadata",
            "gateway_id": normalize_guid(gateway.get("gatewayId")) or fallback_gateway_id,
            "gateway_name": clean_text(gateway.get("gatewayName")),
            "cluster_id": lower_id(gateway.get("clusterId")),
            "cluster_name": clean_text(gateway.get("clusterName")),
            "version": clean_text(gateway.get("version")),
            "service_status": clean_text(gateway.get("serviceStatus")),
            "server_name": clean_text(server.get("serverName")),
            "server_fqdn": clean_text(server.get("serverFqdn")),
            "metadata_server_id": clean_text(server.get("serverId")),
            "number_of_cores": parse_int(server.get("numberOfLogicalProcessors")) or parse_int(server.get("numberOfCores")),
            "memory_mb": parse_int(server.get("totalMemoryMB")),
            "memory_reported": parse_int(server.get("totalMemoryMB")),
            "os_architecture": clean_text(server.get("osArchitecture")),
            "os_version": clean_text(server.get("osVersion")),
            "time_zone_id": clean_text(server.get("timeZoneId")),
            "utc_offset_minutes": parse_int(server.get("utcOffsetMinutes")),
            "metadata_agent_version": clean_text(agent.get("version")),
            "collected_utc": parse_utc(document.get("collectedUtc")),
        }
    cpu = document.get("CpuRelatedInfo") if isinstance(document.get("CpuRelatedInfo"), dict) else None
    cores = parse_int(cpu.get("NumberOfLogicalProcessors")) if cpu else parse_int(document.get("NumberOfCores"))
    return {
        "metadata_source": "gateway-properties",
        "gateway_id": normalize_guid(document.get("GatewayObjectId")) or fallback_gateway_id,
        "gateway_name": clean_text(document.get("GatewayName")),
        "cluster_id": None,
        "cluster_name": clean_text(document.get("GatewayCluster")),
        "version": _version_after_colon(document.get("LocalVersionNumber")),
        "service_status": None,
        "server_name": clean_text(document.get("MachineName")),
        "server_fqdn": None,
        "metadata_server_id": None,
        "number_of_cores": cores,
        "memory_mb": None,
        "memory_reported": parse_int(document.get("SystemTotalMemory")),
        "os_architecture": clean_text(document.get("OSArchitecture")),
        "os_version": clean_text(document.get("OSVersion")),
        "time_zone_id": None,
        "utc_offset_minutes": None,
        "metadata_agent_version": None,
        "collected_utc": None,
    }


def normalize_gateway_clusters(document: Any) -> List[Dict[str, Any]]:
    """GatewayClusters.txt → (cluster, member gateway) rows."""
    clusters = document if isinstance(document, list) else (document.get("value") if isinstance(document, dict) else None)
    if not isinstance(clusters, list):
        raise ValueError("GatewayClusters document is not a list")
    rows = []
    for cluster in clusters:
        if not isinstance(cluster, dict):
            continue
        name = clean_text(cluster.get("name"))
        cluster_id = lower_id(cluster.get("id") or cluster.get("objectId") or cluster.get("clusterObjectId"))
        for member in cluster.get("gateways") or []:
            if not isinstance(member, dict):
                continue
            gateway_id = normalize_guid(member.get("gatewayObjectId"))
            if gateway_id:
                rows.append({
                    "cluster_name": name,
                    "cluster_id": cluster_id,
                    "gateway_id": gateway_id,
                    "gateway_status": clean_text(member.get("gatewayStatus")),
                })
    return rows


def extra_columns_json(extras: Dict[str, Any], max_chars: int) -> Optional[str]:
    if not extras:
        return None
    text = compact_json(extras)
    return text if len(text) <= max_chars else text[:max_chars]


def to_silver_rows(bronze: Dict[str, Any], settings: Dict[str, Any], redactor: Optional[Redactor] = None
                   ) -> List[Tuple[str, Dict[str, Any]]]:
    """Normalize one Bronze record into (silver table, row) pairs. Raises ValueError for rejected records.

    ``bronze`` carries the Bronze columns (record_text, record_fields_json, log_type, gateway_id, ...).
    Lineage columns are added by the caller.
    """
    log_type = bronze.get("log_type")
    target = LOG_TYPES.get(log_type, {}).get("silver")
    if target is None:
        return []
    if bronze.get("parse_status") == "malformed":
        raise ValueError(bronze.get("parse_error") or "malformed record")
    max_extra = settings.get("extraColumnsMaxChars", 8000)
    fallback_gateway = normalize_guid(bronze.get("gateway_id")) or clean_text(bronze.get("gateway_id"))
    text = bronze.get("record_text") or ""
    out: List[Tuple[str, Dict[str, Any]]] = []
    if target == "gateway_logs":
        row = normalize_gateway_log(text, settings, redactor)
        out.append(("gateway_logs", row))
        if log_type == "gateway-info":
            trace = extract_artifact_trace(row["event_type"], row["event_text"])
            if trace:
                trace["event_utc"] = row["event_utc"]
                out.append(("artifact_traces", trace))
        return out
    if target in ("query_starts", "query_executions", "query_aggregations", "system_counters"):
        fields = json.loads(bronze.get("record_fields_json") or "{}")
        if target == "query_starts":
            row, extras = normalize_query_start(fields, fallback_gateway, settings, redactor)
        elif target == "query_executions":
            row, extras = normalize_query_execution(fields, settings, redactor)
        elif target == "query_aggregations":
            row, extras = normalize_query_aggregation(fields, fallback_gateway, settings)
        else:
            row, extras = normalize_system_counter(fields, fallback_gateway, settings)
        row["extra_columns"] = extra_columns_json(extras, max_extra)
        return [(target, row)]
    if target == "mashup_logs":
        row, extras = normalize_mashup_log(json.loads(text), settings, redactor)
        row["extra_columns"] = extra_columns_json(extras, max_extra)
        return [(target, row)]
    if target == "mashup_container_profiles":
        row, extras = normalize_mashup_profile(json.loads(text))
        row["extra_columns"] = extra_columns_json(extras, max_extra)
        return [(target, row)]
    if target == "gateway_metadata":
        return [(target, normalize_gateway_metadata(json.loads(text), log_type, fallback_gateway))]
    if target == "gateway_cluster_members":
        return [(target, member) for member in normalize_gateway_clusters(json.loads(text))]
    return []

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Calendar and Time dimensions — pure Python (replicates the original Power Query logic)
# ---------------------------------------------------------------------------------------------------------------

MONTH_NAMES = ("January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
               "November", "December")
WEEKDAY_NAMES = ("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday")


def calendar_range(today: date, fact_dates: Iterable[Optional[date]], future_years: int = 0) -> Tuple[date, date]:
    """Original: 1-Jan of the previous year → 31-Dec of the current year; extended to cover every fact date."""
    start = date(today.year - 1, 1, 1)
    end = date(today.year + max(0, future_years), 12, 31)
    known = [d for d in fact_dates if d is not None]
    if known:
        start = min(start, date(min(known).year, 1, 1))
        end = max(end, date(max(known).year, 12, 31))
    return start, end


def build_calendar_rows(start: date, end: date, today: date, log_dates: Iterable[date] = ()) -> List[Dict[str, Any]]:
    """Rows of gold.calendar. Weeks start on Monday (P_FirstDayOfWeek = 1), ISO weeks (P_UseIsoWeek = true),
    'Week (Relative)' uses Date.StartOfWeek without first-day argument (en-US → Sunday), exactly like the original."""
    dates_with_logs = set(log_dates)
    today_sunday = today - timedelta(days=(today.weekday() + 1) % 7)
    rows: List[Dict[str, Any]] = []
    current = start
    while current <= end:
        iso_year, iso_week, _ = current.isocalendar()
        quarter = (current.month - 1) // 3 + 1
        semester = 1 if quarter < 3 else 2
        week_day_number = current.isoweekday()
        month_long = MONTH_NAMES[current.month - 1]
        month_short = month_long[:3]
        week_start = current - timedelta(days=current.weekday())
        sunday_start = current - timedelta(days=(current.weekday() + 1) % 7)
        year_relative = current.year - today.year
        rows.append({
            "date": current,
            "date_id": current.year * 10000 + current.month * 100 + current.day,
            "day": current.day,
            "day_relative": (current - today).days,
            "has_logs": current in dates_with_logs,
            "month_short": month_short,
            "month_number": current.month,
            "month_long": month_long,
            "month_relative": year_relative * 12 + (current.month - today.month),
            "month_year": f"{month_short} {current.year}",
            "month_year_id": current.year * 100 + current.month,
            "quarter": quarter,
            "quarter_year": f"Q{quarter} {current.year}",
            "quarter_year_id": current.year * 100 + quarter,
            "semester": semester,
            "semester_year": f"S{semester} {current.year}",
            "semester_year_id": current.year * 100 + semester,
            "week": iso_week,
            "week_relative": (sunday_start - today_sunday).days // 7,
            "week_year": f"W{iso_week} {iso_year}",
            "week_day": WEEKDAY_NAMES[current.weekday()],
            "week_day_number": week_day_number,
            "week_end_date": week_start + timedelta(days=6),
            "week_start_date": week_start,
            "week_year_id": iso_year * 100 + iso_week,
            "work_day": "Weekend" if week_day_number > 5 else "WorkDay",
            "year": current.year,
            "year_relative": year_relative,
        })
        current += timedelta(days=1)
    return rows


def build_time_rows() -> List[Dict[str, Any]]:
    """1,440 rows of gold.time_of_day (minute grain, TimeId = HHmm) with the original day periods."""
    rows: List[Dict[str, Any]] = []
    for hour in range(24):
        for minute in range(60):
            period = next(p for p in DAY_PERIODS if p[0] <= (hour, minute) <= p[1])
            rows.append({
                "time_id": hour * 100 + minute,
                "hour": TIME_EPOCH.replace(hour=hour),
                "hour_number": hour,
                "minute": TIME_EPOCH.replace(hour=hour, minute=minute),
                "minute_number": minute,
                "quarter_hour": TIME_EPOCH.replace(hour=hour, minute=(minute // 15) * 15),
                "half_hour": TIME_EPOCH.replace(hour=hour, minute=(minute // 30) * 30),
                "day_period": period[2],
                "day_period_start": TIME_EPOCH.replace(hour=period[0][0], minute=period[0][1]),
                "day_period_end": TIME_EPOCH.replace(hour=period[1][0], minute=period[1][1]),
            })
    return rows

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Table contracts — single source of truth for Delta schemas, documentation and semantic-model mapping
# ---------------------------------------------------------------------------------------------------------------


def _c(name: str, data_type: str, nullable: bool = True, model: Optional[str] = None, description: str = "") -> Dict[str, Any]:
    return {"name": name, "type": data_type, "nullable": nullable, "model": model, "description": description}


def _silver_head(file_model: Optional[str] = None) -> List[Dict[str, Any]]:
    return [
        _c("record_key", "string", False, None, "Content-addressed key: SHA-256(log_type, gateway_id, raw record)"),
        _c("record_id", "string", True, None, "Bronze record id: SHA-256(segment_id, record index)"),
        _c("segment_id", "string", True, None, "Uploaded segment that contained the record"),
        _c("gateway_id", "string", True, None, "Gateway node object id (lower-case GUID)"),
        _c("cluster_id", "string", True, None, "Gateway cluster id"),
        _c("environment", "string", True, None, "Environment label configured on the agent"),
        _c("server_id", "string", True, None, "Truncated SHA-256 of the server MachineGuid"),
        _c("server_name", "string", True, None, "Server host name"),
        _c("log_type", "string", True, None, "Log type (see architecture §3.2)"),
        _c("source_file_name", "string", True, file_model, "Original gateway log file name"),
    ]


def _silver_tail(partitioned: bool = True) -> List[Dict[str, Any]]:
    columns = [
        _c("ingest_batch_id", "string", True, None, "Bronze batch that ingested the record"),
        _c("ingested_utc", "timestamp", True, None, "Bronze ingestion time (UTC)"),
        _c("processed_utc", "timestamp", True, None, "Silver processing time (UTC)"),
    ]
    if partitioned:
        columns += [
            _c("event_date", "date", True, None, "Event date (UTC)"),
            _c("event_month", "int", False, None, "Partition: event month yyyyMM (UTC)"),
        ]
    return columns


TABLES: Dict[str, Dict[str, Any]] = {}


def _table(key: str, description: str, grain: str, primary_key: List[str], columns: List[Dict[str, Any]],
           partition_by: Optional[List[str]] = None, dedup: str = "", retention: str = "",
           model_table: Optional[str] = None, source: str = "") -> None:
    layer, name = key.split(".")
    TABLES[key] = {
        "layer": layer, "name": name, "description": description, "grain": grain, "key": primary_key,
        "columns": columns, "partition_by": partition_by or [], "dedup": dedup, "retention": retention,
        "model_table": model_table, "source": source,
    }


# ----- Bronze ---------------------------------------------------------------------------------------------------
_table(
    "bronze.gateway_records",
    "Raw gateway log records exactly as uploaded, with ingestion metadata. CSV rows also keep a header-keyed JSON "
    "object so later gateway versions with new columns never break ingestion.",
    "One record of one uploaded segment", ["record_id"],
    [
        _c("record_id", "string", False, None, "SHA-256(segment_id, record index)"),
        _c("record_key", "string", False, None, "SHA-256(log_type, gateway_id, [snapshot fingerprint], raw record)"),
        _c("segment_id", "string", False, None, "Segment identifier from the manifest"),
        _c("record_index", "bigint", False, None, "Position of the record inside the segment"),
        _c("record_offset", "bigint", True, None, "Absolute byte offset in the source file (null for UTF-16 files)"),
        _c("log_type", "string", False, None, "Log type"),
        _c("record_format", "string", False, None, "trace | jsonl | csv | profile | json"),
        _c("record_text", "string", True, None, "Raw record text (truncated to bronze.maxRecordChars)"),
        _c("record_fields_json", "string", True, None, "CSV only: JSON object keyed by the file header"),
        _c("record_truncated", "boolean", True, None, "True when record_text was truncated"),
        _c("parse_status", "string", False, None, "ok | malformed"),
        _c("parse_error", "string", True, None, "Reason when malformed"),
        _c("environment", "string", True, None, "Environment"),
        _c("cluster_id", "string", True, None, "Gateway cluster id"),
        _c("gateway_id", "string", True, None, "Gateway node id resolved by the agent"),
        _c("server_name", "string", True, None, "Server host name"),
        _c("server_id", "string", True, None, "Server id"),
        _c("agent_instance_id", "string", True, None, "Agent installation id"),
        _c("agent_version", "string", True, None, "Agent version"),
        _c("source_name", "string", True, None, "Agent source name"),
        _c("source_file_name", "string", True, None, "Original file name"),
        _c("source_file_path", "string", True, None, "Original file path on the gateway server"),
        _c("source_fingerprint", "string", True, None, "SHA-256 of the first KiB (incremental) or content (snapshot)"),
        _c("source_last_write_utc", "timestamp", True, None, "Source file last write time (UTC)"),
        _c("raw_path", "string", True, None, "Path of the segment relative to the landing root"),
        _c("manifest_run_id", "string", True, None, "Agent run id of the manifest"),
        _c("uploaded_utc", "timestamp", True, None, "Upload time reported by the agent (UTC)"),
        _c("ingest_batch_id", "string", False, None, "Bronze batch id"),
        _c("ingested_utc", "timestamp", False, None, "Bronze ingestion time (UTC)"),
        _c("ingest_date", "date", False, None, "Partition: ingestion date (UTC)"),
    ],
    partition_by=["ingest_date"],
    dedup="Segments already in ops.segment_registry are skipped; insert-only MERGE on record_id",
    retention="retention.bronzeDays (default 30)",
    source="landing/raw segments listed in landing/manifests",
)

# ----- Silver ---------------------------------------------------------------------------------------------------
_table(
    "silver.gateway_logs",
    "Parsed gateway trace records (GatewayInfo, GatewayErrors, GatewayNetwork).",
    "One trace record", ["record_key"],
    _silver_head() + [
        _c("instance", "string", True, None, "Trace source, e.g. DM.EnterpriseGateway"),
        _c("level", "string", True, None, "Information, Error, Warning, Verbose"),
        _c("event_utc", "timestamp", True, None, "Event timestamp (UTC, 1 µs precision)"),
        _c("activity_id", "string", True, None, "Activity id"),
        _c("root_activity_id", "string", True, None, "Root activity (request) id"),
        _c("activity_type", "string", True, None, "Activity type code"),
        _c("client_activity_id", "string", True, None, "Client activity id"),
        _c("root_gateway_client_pipeline_id", "string", True, None, "Root gateway client pipeline id (SourceId)"),
        _c("current_gateway_client_pipeline_id", "string", True, None, "Current gateway client pipeline id (HelperId)"),
        _c("hash", "string", True, None, "Event hash"),
        _c("event_type", "string", True, None, "Event type, e.g. [DM.GatewayCore]"),
        _c("event_text", "string", True, None, "Full event text (redaction rules applied)"),
        _c("event_text_length", "int", True, None, "Length of the event text"),
        _c("record_offset", "bigint", True, None, "Byte offset in the source file"),
    ] + _silver_tail(),
    partition_by=["event_month"], dedup="Insert-only MERGE on record_key", retention="retention.silverDays (default 400)",
    source="bronze.gateway_records where log_type in gateway-info/errors/network",
)
_table(
    "silver.artifact_traces",
    "Evaluation trace contexts (dataset/workspace ids per request) extracted from GatewayInfo records.",
    "One EvaluationTraceContext record", ["record_key"],
    [
        _c("record_key", "string", False, None, "Key of the source trace record"),
        _c("record_id", "string", True, None, "Bronze record id"),
        _c("segment_id", "string", True, None, "Segment id"),
        _c("gateway_id", "string", True, None, "Gateway node id"),
        _c("environment", "string", True, None, "Environment"),
        _c("server_id", "string", True, None, "Server id"),
        _c("source_file_name", "string", True, None, "Log file name"),
        _c("event_utc", "timestamp", True, None, "Event timestamp (UTC)"),
        _c("root_activity_id", "string", True, None, "Root activity id"),
        _c("current_activity_id", "string", True, None, "Current activity id"),
        _c("dataset_id", "string", True, None, "Semantic model (dataset) id"),
        _c("query_type", "string", True, None, "Query type"),
        _c("sku", "string", True, None, "Capacity SKU"),
        _c("workspace_id", "string", True, None, "Workspace id"),
    ] + _silver_tail(),
    partition_by=["event_month"], dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="silver.gateway_logs (gateway-info)",
)
_table(
    "silver.query_starts",
    "Query Start Report rows.", "One query start", ["record_key"],
    _silver_head() + [
        _c("request_id", "string", True, None, "Request id"),
        _c("query_tracking_id", "string", True, None, "Query tracking id"),
        _c("query_start_utc", "timestamp", True, None, "QueryExecutionStartTimeUTC"),
        _c("query_type", "string", True, None, "Refresh, DirectQuery, ..."),
        _c("data_source", "string", True, None, "DataSource (JSON)"),
        _c("query_text", "string", True, None, "Decoded query text (redaction rules applied)"),
        _c("query_text_length", "int", True, None, "Length of the decoded query text"),
        _c("evaluation_context", "string", True, None, "EvaluationContext (newer gateways)"),
        _c("extra_columns", "string", True, None, "Unknown columns (schema drift) as JSON"),
    ] + _silver_tail(),
    partition_by=["event_month"], dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="bronze.gateway_records where log_type = query-start-report",
)
_table(
    "silver.query_executions",
    "Query Execution Report rows.", "One query execution", ["record_key"],
    _silver_head() + [
        _c("request_id", "string", True, None, "Request id"),
        _c("query_tracking_id", "string", True, None, "Query tracking id"),
        _c("data_source", "string", True, None, "DataSource (JSON)"),
        _c("query_type", "string", True, None, "Query type"),
        _c("query_execution_end_utc", "timestamp", True, None, "QueryExecutionEndTimeUTC"),
        _c("query_execution_duration_ms", "bigint", True, None, "QueryExecutionDuration(ms)"),
        _c("data_reading_and_serialization_duration_ms", "bigint", True, None, "DataReadingAndSerializationDuration(ms)"),
        _c("spooling_disk_writing_duration_ms", "bigint", True, None, "SpoolingDiskWritingDuration(ms)"),
        _c("spooling_disk_reading_duration_ms", "bigint", True, None, "SpoolingDiskReadingDuration(ms)"),
        _c("spooling_total_data_size_bytes", "bigint", True, None, "SpoolingTotalDataSize(byte)"),
        _c("data_processing_end_utc", "timestamp", True, None, "DataProcessingEndTimeUTC"),
        _c("data_processing_duration_ms", "bigint", True, None, "DataProcessingDuration(ms)"),
        _c("success", "string", True, None, "Y / N"),
        _c("error_message", "string", True, None, "Error message (redaction rules applied)"),
        _c("extra_columns", "string", True, None, "Unknown columns (schema drift) as JSON"),
    ] + _silver_tail(),
    partition_by=["event_month"], dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="bronze.gateway_records where log_type = query-execution-report",
)
_table(
    "silver.query_aggregations",
    "Query Execution Aggregation Report rows (not used by the original model; available for SQL analysis).",
    "Aggregation window × data source × success × query type", ["record_key"],
    _silver_head() + [
        _c("aggregation_start_utc", "timestamp", True, None, "AggregationStartTimeUTC"),
        _c("aggregation_end_utc", "timestamp", True, None, "AggregationEndTimeUTC"),
        _c("data_source", "string", True, None, "DataSource (JSON)"),
        _c("success", "string", True, None, "Success"),
        _c("average_query_execution_duration_ms", "double", True, None, "AverageQueryExecutionDuration(ms)"),
        _c("max_query_execution_duration_ms", "double", True, None, "MaxQueryExecutionDuration(ms)"),
        _c("min_query_execution_duration_ms", "double", True, None, "MinQueryExecutionDuration(ms)"),
        _c("query_type", "string", True, None, "QueryType"),
        _c("average_data_processing_duration_ms", "double", True, None, "AverageDataProcessingDuration(ms)"),
        _c("max_data_processing_duration_ms", "double", True, None, "MaxDataProcessingDuration(ms)"),
        _c("min_data_processing_duration_ms", "double", True, None, "MinDataProcessingDuration(ms)"),
        _c("query_count", "bigint", True, None, "Count"),
        _c("extra_columns", "string", True, None, "Unknown columns (schema drift) as JSON"),
    ] + _silver_tail(),
    partition_by=["event_month"], dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="bronze.gateway_records where log_type = query-execution-aggregation-report",
)
_table(
    "silver.system_counters",
    "System Counter Aggregation Report rows.", "Counter × aggregation window", ["record_key"],
    _silver_head() + [
        _c("aggregation_start_utc", "timestamp", True, None, "AggregationStartTimeUTC"),
        _c("aggregation_end_utc", "timestamp", True, None, "AggregationEndTimeUTC"),
        _c("counter_name", "string", True, None, "SystemCPUPercent, SystemMEMUsedPercent, GatewayCPUPercent, GatewayMEMKb, ..."),
        _c("max_value", "double", True, None, "Max"),
        _c("min_value", "double", True, None, "Min"),
        _c("average_value", "double", True, None, "Average"),
        _c("extra_columns", "string", True, None, "Unknown columns (schema drift) as JSON"),
    ] + _silver_tail(),
    partition_by=["event_month"], dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="bronze.gateway_records where log_type = system-counter-aggregation-report",
)
_table(
    "silver.mashup_logs",
    "Mashup engine log events (JSON lines).", "One mashup event", ["record_key"],
    _silver_head() + [
        _c("start_utc", "timestamp", True, None, "Start"),
        _c("action", "string", True, None, "Action"),
        _c("action_group", "string", True, None, "Action before the first '/'"),
        _c("action_detail", "string", True, None, "Action after the first '/'"),
        _c("product_version", "string", True, None, "ProductVersion"),
        _c("activity_id", "string", True, None, "ActivityId"),
        _c("process", "string", True, None, "Process"),
        _c("pid", "bigint", True, None, "Pid"),
        _c("duration_ms", "double", True, None, "Duration in milliseconds"),
        _c("resource_kind", "string", True, None, "ResourceKind"),
        _c("resource_path", "string", True, None, "ResourcePath"),
        _c("row_count", "bigint", True, None, "RowCount"),
        _c("connection_timeout", "bigint", True, None, "ConnectionTimeout"),
        _c("exception", "string", True, None, "Exception (redaction rules applied)"),
        _c("identity", "string", True, None, "identity ('Default' when missing)"),
        _c("container_id", "bigint", True, None, "containerID"),
        _c("pool_count", "bigint", True, None, "poolCount"),
        _c("running_count", "bigint", True, None, "runningCount"),
        _c("pending_count", "bigint", True, None, "pendingCount"),
        _c("non_fatal_error", "string", True, None, "NonFatalError"),
        _c("command_text", "string", True, None, "CommandText (redaction rules applied)"),
        _c("command_timeout", "bigint", True, None, "CommandTimeout"),
        _c("engine_edition", "string", True, None, "EngineEdition"),
        _c("firewall_group", "string", True, None, "FirewallGroup"),
        _c("error_yn", "string", True, None, "'Y' when Exception is present"),
        _c("extra_columns", "string", True, None, "Unknown fields (schema drift) as JSON"),
    ] + _silver_tail(),
    partition_by=["event_month"], dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="bronze.gateway_records where log_type = mashup",
)
_table(
    "silver.mashup_container_profiles",
    "Mashup container pool settings from MashupContainerProfiles.log snapshots.",
    "Snapshot × pool type", ["record_key"],
    _silver_head() + [
        _c("snapshot_key", "string", True, None, "Content hash of the snapshot file"),
        _c("snapshot_utc", "timestamp", True, None, "Source last write time (or upload time)"),
        _c("pool_type_id", "bigint", True, None, "MashupContainerPoolType"),
        _c("pool_type", "string", True, None, "Pool type name"),
        _c("container_max_count", "bigint", True, None, "ContainerMaxCount"),
        _c("container_max_working_set_in_mb", "bigint", True, None, "ContainerMaxWorkingSetInMB"),
        _c("container_max_commit_in_mb", "bigint", True, None, "ContainerMaxCommitInMB"),
        _c("container_time_to_live_in_minute", "bigint", True, None, "ContainerTimeToLiveInMinute"),
        _c("cache_time_to_live_in_minute", "bigint", True, None, "CacheTimeToLiveInMinute"),
        _c("session_time_to_live_in_minute", "bigint", True, None, "SessionTimeToLiveInMinute"),
        _c("enable_caching", "boolean", True, None, "EnableCaching"),
        _c("metadata_cache_time_to_live_in_minute", "bigint", True, None, "MetadataCacheTimeToLiveInMinute"),
        _c("metadata_cache_max_size_in_mb", "bigint", True, None, "MetadataCacheMaxSizeInMB"),
        _c("data_cache_time_to_live_in_minute", "bigint", True, None, "DataCacheTimeToLiveInMinute"),
        _c("data_cache_max_size_in_mb", "bigint", True, None, "DataCacheMaxSizeInMB"),
        _c("extra_columns", "string", True, None, "Unknown fields as JSON"),
    ] + _silver_tail(partitioned=False),
    dedup="Insert-only MERGE on record_key (includes the snapshot hash)", retention="retention.silverDays",
    source="bronze.gateway_records where log_type = mashup-container-profiles",
)
_table(
    "silver.gateway_metadata",
    "Gateway/server metadata snapshots from the agent (agent-metadata) and exported GatewayProperties.txt.",
    "Metadata snapshot", ["record_key"],
    _silver_head() + [
        _c("snapshot_key", "string", True, None, "Content hash of the snapshot"),
        _c("snapshot_utc", "timestamp", True, None, "Collection time"),
        _c("metadata_source", "string", True, None, "agent-metadata | gateway-properties"),
        _c("gateway_name", "string", True, None, "Gateway name"),
        _c("cluster_name", "string", True, None, "Cluster name"),
        _c("version", "string", True, None, "Gateway version"),
        _c("service_status", "string", True, None, "Gateway Windows service status"),
        _c("server_fqdn", "string", True, None, "Server FQDN"),
        _c("metadata_server_id", "string", True, None, "Server id reported in the document"),
        _c("number_of_cores", "bigint", True, None, "Logical processors"),
        _c("memory_mb", "bigint", True, None, "Total memory (MB) reported by the agent"),
        _c("memory_reported", "bigint", True, None, "SystemTotalMemory as reported (unit as in the source)"),
        _c("os_architecture", "string", True, None, "OS architecture"),
        _c("os_version", "string", True, None, "OS version"),
        _c("time_zone_id", "string", True, None, "Windows time zone id"),
        _c("utc_offset_minutes", "int", True, None, "UTC offset at collection time"),
        _c("metadata_agent_version", "string", True, None, "Agent version that produced the snapshot"),
        _c("collected_utc", "timestamp", True, None, "collectedUtc"),
    ] + _silver_tail(partitioned=False),
    dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="bronze.gateway_records where log_type in agent-metadata, gateway-properties",
)
_table(
    "silver.gateway_cluster_members",
    "Cluster membership from exported GatewayClusters.txt files.", "Snapshot × member gateway", ["record_key"],
    _silver_head() + [
        _c("snapshot_key", "string", True, None, "Content hash of the snapshot"),
        _c("snapshot_utc", "timestamp", True, None, "Snapshot time"),
        _c("cluster_name", "string", True, None, "Cluster name"),
        _c("gateway_status", "string", True, None, "Member status"),
    ] + _silver_tail(partitioned=False),
    dedup="Insert-only MERGE on record_key", retention="retention.silverDays",
    source="bronze.gateway_records where log_type = gateway-clusters",
)

# ----- Gold (semantic model tables) ------------------------------------------------------------------------------
_table(
    "gold.calendar", "Date dimension (UTC dates).", "Day", ["date"],
    [
        _c("date", "date", False, "Date"), _c("date_id", "int", True, "DateId"), _c("day", "int", True, "Day"),
        _c("day_relative", "int", True, "Day (Relative)"), _c("has_logs", "boolean", True, "Has Logs?"),
        _c("month_short", "string", True, "Month"), _c("month_number", "int", True, "Month (#)"),
        _c("month_long", "string", True, "Month (Long)"), _c("month_relative", "int", True, "Month (Relative)"),
        _c("month_year", "string", True, "Month (Year)"), _c("month_year_id", "int", True, "MonthYearId"),
        _c("quarter", "int", True, "Quarter"), _c("quarter_year", "string", True, "Quarter (Year)"),
        _c("quarter_year_id", "int", True, "QuarterYearId"), _c("semester", "int", True, "Semester"),
        _c("semester_year", "string", True, "Semester (Year)"), _c("semester_year_id", "int", True, "SemesterYearId"),
        _c("week", "int", True, "Week"), _c("week_relative", "int", True, "Week (Relative)"),
        _c("week_year", "string", True, "Week (Year)"), _c("week_day", "string", True, "Week Day"),
        _c("week_day_number", "int", True, "Week Day (#)"), _c("week_end_date", "date", True, "Week End Date"),
        _c("week_start_date", "date", True, "Week Start Date"), _c("week_year_id", "int", True, "WeekYearId"),
        _c("work_day", "string", True, "Work Day"), _c("year", "int", True, "Year"),
        _c("year_relative", "int", True, "Year (Relative)"),
    ],
    dedup="Rebuilt every run", retention="1-Jan previous year → 31-Dec current year, extended to fact dates",
    model_table="Calendar", source="Generated",
)
_table(
    "gold.time_of_day", "Minute-grain time dimension (UTC).", "Minute", ["time_id"],
    [
        _c("time_id", "int", False, "TimeId"), _c("hour", "timestamp", True, "Hour"),
        _c("hour_number", "int", True, "Hour (#)"), _c("minute", "timestamp", True, "Minute"),
        _c("minute_number", "int", True, "Minute (#)"), _c("quarter_hour", "timestamp", True, "Quarter Hour"),
        _c("half_hour", "timestamp", True, "Half Hour"), _c("day_period", "string", True, "Day Period"),
        _c("day_period_start", "timestamp", True, "Day Period Start"),
        _c("day_period_end", "timestamp", True, "Day Period End"),
    ],
    dedup="Rebuilt every run", retention="Static (1,440 rows)", model_table="Time", source="Generated",
)
_table(
    "gold.gateways", "Gateway node dimension (one row per GatewayObjectId ever seen).", "Gateway node",
    ["gateway_id"],
    [
        _c("gateway_id", "string", False, "GatewayId", "Gateway node object id"),
        _c("gateway_name", "string", True, "Gateway", "Gateway name (falls back to the id)"),
        _c("cluster_name", "string", True, "Cluster", "Cluster name (falls back to the gateway name)"),
        _c("server_name", "string", True, "Server", "Latest server hosting the gateway"),
        _c("version", "string", True, "Version", "Gateway version"),
        _c("number_of_cores", "bigint", True, "NumberOfCores", "Logical processors of the server"),
        _c("memory", "bigint", True, "Memory", "Total memory (MB when reported by the agent)"),
        _c("os_architecture", "string", True, "OSArchitecture", "OS architecture"),
        _c("os_version", "string", True, "OSVersion", "OS version"),
        _c("cluster_id", "string", True, "Cluster Id", "Gateway cluster id"),
        _c("environment", "string", True, "Environment", "Environment label"),
        _c("server_id", "string", True, "Server Id", "Server id"),
        _c("installation_id", "string", True, "Installation Id", "SHA-256(server_id, gateway_id) truncated"),
        _c("agent_version", "string", True, "Agent Version", "Latest collection agent version"),
        _c("first_seen_utc", "timestamp", True, "First Seen (UTC)", "First event or upload"),
        _c("last_seen_utc", "timestamp", True, "Last Seen (UTC)", "Last event or upload"),
        _c("status", "string", True, "Status", "Active / Inactive (no data for gold.inactiveAfterDays)"),
    ],
    dedup="Rebuilt every run; manual overrides > GatewayClusters > metadata > defaults",
    retention="All gateways seen in Silver or registries", model_table="Gateways",
    source="silver.gateway_metadata, silver.gateway_cluster_members, gateway-overrides.json, facts, ops registries",
)
_table(
    "gold.logs", "Gateway log records loaded into the model (gold.logTypes).", "Log record", ["record_key"],
    [
        _c("record_key", "string", False, None, "Record key"),
        _c("activity_id", "string", True, "ActivityId"), _c("activity_type", "string", True, "ActivityType"),
        _c("client_activity_id", "string", True, "ClientActivityId"),
        _c("current_gateway_client_pipeline_id", "string", True, "CurrentGatewayClientPipelineId"),
        _c("date", "date", True, "Date"), _c("date_time", "timestamp", True, "DateTime", "Event time truncated to the minute (UTC)"),
        _c("event_text", "string", True, "EventText", "Event text truncated to gold.maxLogTextLength"),
        _c("event_type", "string", True, "EventType"), _c("gateway_id", "string", True, "GatewayId"),
        _c("hash", "string", True, "Hash"), _c("hour", "timestamp", True, "Hour", "Time of day (UTC)"),
        _c("instance", "string", True, "Instance"), _c("level", "string", True, "Level"),
        _c("log_file_name", "string", True, "LogFileName"), _c("root_activity_id", "string", True, "RootActivityId"),
        _c("root_gateway_client_pipeline_id", "string", True, "RootGatewayClientPipelineId"),
        _c("time_id", "int", True, "TimeId"), _c("log_type", "string", True, "Log Type", "gateway-info, gateway-errors, gateway-network"),
        _c("event_utc", "timestamp", True, None, "Full-precision event time (UTC)"),
        _c("server_id", "string", True, None, "Server id"),
        _c("event_month", "int", False, None, "Partition: event month yyyyMM"),
    ],
    partition_by=["event_month"], dedup="Recomputed per affected month from silver.gateway_logs",
    retention="gold.windowDays (default 180)", model_table="Logs", source="silver.gateway_logs",
)
_table(
    "gold.logs_artifact_trace", "Dataset/workspace ids per request extracted from evaluation traces.",
    "(gateway, root activity, dataset)", ["gateway_id", "root_activity_id", "dataset_id"],
    [
        _c("current_activity_id", "string", True, "CurrentActivityId"), _c("dataset_id", "string", True, "DatasetId"),
        _c("gateway_id", "string", True, "GatewayId"), _c("log_file_name", "string", True, "LogFileName"),
        _c("query_type", "string", True, "QueryType"), _c("root_activity_id", "string", True, "RootActivityId"),
        _c("sku", "string", True, "SKU"), _c("workspace_id", "string", True, "WorkspaceId"),
    ],
    dedup="Distinct (gateway_id, root_activity_id, dataset_id), rebuilt every run",
    retention="gold.windowDays", model_table="LogsArtifactTrace", source="silver.artifact_traces",
)
_table(
    "gold.queries", "Gateway queries (start ⟕ execution).", "Query (QueryTrackingId)", ["query_tracking_id"],
    [
        _c("data_processing_duration_ms", "bigint", True, "DataProcessingDuration(ms)"),
        _c("data_reading_and_serialization_duration_ms", "bigint", True, "DataReadingAndSerializationDuration(ms)"),
        _c("dataset_id", "string", True, "DatasetId"), _c("datasources", "string", True, "Datasources"),
        _c("date_time", "timestamp", True, "DateTime"), _c("end_date", "date", True, "End Date"),
        _c("end_time", "timestamp", True, "End Time"), _c("error_message", "string", True, "ErrorMessage"),
        _c("file_name", "string", True, "Filename"), _c("gateway_id", "string", True, "GatewayId"),
        _c("query_execution_duration_ms", "bigint", True, "QueryExecutionDuration(ms)"),
        _c("query_text", "string", True, "QueryText"), _c("query_tracking_id", "string", False, "QueryTrackingId"),
        _c("query_type", "string", True, "QueryType"), _c("request_id", "string", True, "RequestId"),
        _c("spooling_disk_reading_duration_ms", "bigint", True, "SpoolingDiskReadingDuration(ms)"),
        _c("spooling_disk_writing_duration_ms", "bigint", True, "SpoolingDiskWritingDuration(ms)"),
        _c("spooling_total_data_size_bytes", "bigint", True, "SpoolingTotalDataSize(byte)"),
        _c("start_date", "date", True, "Start Date"), _c("start_time", "timestamp", True, "Start Time"),
        _c("success", "string", True, "Success"), _c("time_id", "int", True, "TimeId"),
        _c("total_query_execution_ms", "bigint", True, "TotalQueryExecution(ms)"),
        _c("workspace_id", "string", True, "WorkspaceId"),
        _c("evaluation_context", "string", True, "EvaluationContext", "EvaluationContext column of newer gateways"),
        _c("query_start_utc", "timestamp", True, None, "Full-precision start (UTC)"),
        _c("query_end_utc", "timestamp", True, None, "Full-precision end: DataProcessingEndTimeUTC ?? QueryExecutionEndTimeUTC"),
        _c("server_id", "string", True, None, "Server id"),
        _c("event_month", "int", False, None, "Partition: start month yyyyMM"),
    ],
    partition_by=["event_month"],
    dedup="One row per query_tracking_id: latest start attempt, latest matching execution",
    retention="gold.windowDays", model_table="Queries", source="silver.query_starts, silver.query_executions, silver.artifact_traces",
)
_table(
    "gold.query_datasources", "Data sources of each query.", "(query, data source)",
    ["query_tracking_id", "datasource_kind", "datasource_path"],
    [
        _c("query_tracking_id", "string", True, "QueryTrackingId"),
        _c("datasource_kind", "string", True, "DataSource - Kind"),
        _c("datasource_path", "string", True, "DataSource - Path"),
        _c("event_month", "int", False, None, "Partition: query start month"),
    ],
    partition_by=["event_month"], dedup="Distinct per query", retention="gold.windowDays",
    model_table="Queries - Datasources", source="silver.query_starts",
)
_table(
    "gold.requests", "Requests (root activities) derived from logs and queries.", "Request", ["request_id"],
    [
        _c("request_id", "string", False, "RequestId"), _c("request_start", "timestamp", True, "Start"),
        _c("request_end", "timestamp", True, "End"), _c("duration_s", "bigint", True, "Duration"),
        _c("duration_queries_s", "bigint", True, "DurationQueries"), _c("date", "date", True, "Date"),
        _c("has_queries", "string", True, "Has Queries (Y/N)"),
        _c("event_month", "int", False, None, "Partition: start month"),
    ],
    partition_by=["event_month"], dedup="Recomputed for request ids touched by affected months (MERGE)",
    retention="gold.windowDays", model_table="Requests", source="gold.logs, gold.queries",
)
_table(
    "gold.mashup_logs", "Mashup engine events.", "Mashup event", ["record_key"],
    [
        _c("record_key", "string", False, None, "Record key"),
        _c("action", "string", True, "Action"), _c("action_detail", "string", True, "Action Detail"),
        _c("action_group", "string", True, "Action Group"), _c("activity_id", "string", True, "ActivityId"),
        _c("command_text", "string", True, "CommandText"), _c("command_timeout", "bigint", True, "CommandTimeout"),
        _c("connection_timeout", "bigint", True, "ConnectionTimeout"), _c("container_id", "bigint", True, "ContainerID"),
        _c("date", "date", True, "Date"), _c("date_time", "timestamp", True, "DateTime"),
        _c("duration_ms", "double", True, "Duration (ms)"), _c("engine_edition", "string", True, "EngineEdition"),
        _c("error_yn", "string", True, "Error (Y/N)"), _c("exception", "string", True, "Exception"),
        _c("file_name", "string", True, "Filename"), _c("firewall_group", "string", True, "FirewallGroup"),
        _c("gateway_id", "string", True, "GatewayId"), _c("identity", "string", True, "Identity"),
        _c("non_fatal_error", "string", True, "NonFatalError"), _c("pid", "bigint", True, "Pid"),
        _c("process", "string", True, "Process"), _c("product_version", "string", True, "ProductVersion"),
        _c("resource_kind", "string", True, "ResourceKind"), _c("resource_path", "string", True, "ResourcePath"),
        _c("row_count", "bigint", True, "RowCount"), _c("time_of_day", "timestamp", True, "Time"),
        _c("time_id", "int", True, "TimeId"), _c("pending_count", "bigint", True, "pendingCount"),
        _c("pool_count", "bigint", True, "poolCount"), _c("running_count", "bigint", True, "runningCount"),
        _c("server_id", "string", True, None, "Server id"),
        _c("event_month", "int", False, None, "Partition: event month"),
    ],
    partition_by=["event_month"], dedup="Recomputed per affected month", retention="gold.windowDays",
    model_table="Mashup Logs", source="silver.mashup_logs",
)
_table(
    "gold.mashup_container_profile", "Latest mashup container profile per gateway and pool type.",
    "Gateway × pool type", ["gateway_id", "mashup_container_pool_type_id"],
    [
        _c("cache_time_to_live_in_minute", "bigint", True, "CacheTimeToLiveInMinute"),
        _c("container_max_commit_in_mb", "bigint", True, "ContainerMaxCommitInMB"),
        _c("container_max_count", "bigint", True, "ContainerMaxCount"),
        _c("container_max_working_set_in_mb", "bigint", True, "ContainerMaxWorkingSetInMB"),
        _c("container_time_to_live_in_minute", "bigint", True, "ContainerTimeToLiveInMinute"),
        _c("data_cache_max_size_in_mb", "bigint", True, "DataCacheMaxSizeInMB"),
        _c("data_cache_time_to_live_in_minute", "bigint", True, "DataCacheTimeToLiveInMinute"),
        _c("enable_caching", "boolean", True, "EnableCaching"), _c("gateway_id", "string", True, "GatewayId"),
        _c("mashup_container_pool_type", "string", True, "MashupContainerPoolType"),
        _c("mashup_container_pool_type_id", "bigint", True, "MashupContainerPoolTypeId"),
        _c("metadata_cache_max_size_in_mb", "bigint", True, "MetadataCacheMaxSizeInMB"),
        _c("metadata_cache_time_to_live_in_minute", "bigint", True, "MetadataCacheTimeToLiveInMinute"),
        _c("session_time_to_live_in_minute", "bigint", True, "SessionTimeToLiveInMinute"),
        _c("snapshot_utc", "timestamp", True, None, "Snapshot time"),
    ],
    dedup="Latest snapshot per gateway", retention="Latest only", model_table="Mashup Container Profile",
    source="silver.mashup_container_profiles",
)
_table(
    "gold.system_counters", "Gateway performance counters (5-minute aggregation windows by default).",
    "Counter × window", ["record_key"],
    [
        _c("record_key", "string", False, None, "Record key"),
        _c("aggregation_end_time_utc", "timestamp", True, "AggregationEndTimeUTC"),
        _c("aggregation_start_time_utc", "timestamp", True, "AggregationStartTimeUTC"),
        _c("average_value", "double", True, "Average"), _c("counter_name", "string", True, "CounterName"),
        _c("date", "date", True, "Date"), _c("file_name", "string", True, "Filename"),
        _c("gateway_id", "string", True, "GatewayId"), _c("max_value", "double", True, "Max"),
        _c("min_value", "double", True, "Min"), _c("tme_id", "int", True, "TmeId"),
        _c("server_id", "string", True, None, "Server id"),
        _c("event_month", "int", False, None, "Partition: window end month"),
    ],
    partition_by=["event_month"], dedup="Recomputed per affected month", retention="gold.windowDays",
    model_table="System Counters", source="silver.system_counters",
)

# ----- Gold (ingestion health — new) -----------------------------------------------------------------------------
_table(
    "gold.ingestion_servers", "Collection agents / servers with their latest status (new ingestion metric).",
    "Server", ["server_id"],
    [
        _c("server_id", "string", False, "ServerId"), _c("server_name", "string", True, "Server"),
        _c("server_fqdn", "string", True, "Server FQDN"), _c("environment", "string", True, "Environment"),
        _c("cluster_id", "string", True, "Cluster Id"), _c("cluster_name", "string", True, "Cluster"),
        _c("gateway_id", "string", True, "Gateway Id"), _c("gateway_name", "string", True, "Gateway"),
        _c("agent_instance_id", "string", True, "Agent Instance Id"), _c("agent_version", "string", True, "Agent Version"),
        _c("time_zone_id", "string", True, "Time Zone"), _c("utc_offset_minutes", "int", True, "UTC Offset (min)"),
        _c("first_seen_utc", "timestamp", True, "First Seen (UTC)"),
        _c("last_run_utc", "timestamp", True, "Last Agent Run (UTC)"),
        _c("last_run_status", "string", True, "Last Run Status"),
        _c("last_successful_run_utc", "timestamp", True, "Last Successful Run (UTC)"),
        _c("last_upload_utc", "timestamp", True, "Last Upload (UTC)"),
        _c("last_processed_utc", "timestamp", True, "Last Processed (UTC)"),
        _c("last_processed_file", "string", True, "Last Processed File"),
        _c("expected_interval_minutes", "int", True, "Expected Interval (min)"),
        _c("late_after_minutes", "int", True, "Late After (min)"),
        _c("missing_after_minutes", "int", True, "Missing After (min)"),
    ],
    dedup="Rebuilt every run", retention="Servers with a run in ops.agent_runs", model_table="Servers",
    source="ops.agent_runs, ops.segment_registry, silver.gateway_metadata",
)
_table(
    "gold.ingestion_uploads", "Uploaded segments and their processing status (new ingestion metric).",
    "Uploaded segment", ["segment_id"],
    [
        _c("segment_id", "string", False, "Segment Id"), _c("server_id", "string", True, "ServerId"),
        _c("gateway_id", "string", True, "GatewayId"), _c("environment", "string", True, "Environment"),
        _c("cluster_id", "string", True, "Cluster Id"), _c("log_type", "string", True, "Log Type"),
        _c("source_file_name", "string", True, "Source File"), _c("raw_path", "string", True, "Raw Path"),
        _c("byte_count", "bigint", True, "Bytes"), _c("record_count", "bigint", True, "Records"),
        _c("malformed_count", "bigint", True, "Malformed Records"),
        _c("source_last_write_utc", "timestamp", True, "Source Last Write (UTC)"),
        _c("uploaded_utc", "timestamp", True, "Uploaded (UTC)"), _c("upload_date", "date", True, "Upload Date"),
        _c("processed_utc", "timestamp", True, "Processed (UTC)"), _c("status", "string", True, "Status"),
        _c("attempts", "int", True, "Attempts"),
        _c("upload_latency_minutes", "double", True, "Upload Latency (min)"),
        _c("processing_latency_minutes", "double", True, "Processing Latency (min)"),
        _c("total_latency_minutes", "double", True, "Ingestion Latency (min)"),
        _c("manifest_run_id", "string", True, "Agent Run Id"), _c("error", "string", True, "Error"),
    ],
    dedup="Rebuilt every run", retention="gold.ingestionWindowDays (default 30)", model_table="Ingestion Uploads",
    source="ops.segment_registry",
)
_table(
    "gold.ingestion_agent_runs", "Collection agent runs (heartbeats) (new ingestion metric).", "Agent run", ["run_id"],
    [
        _c("run_id", "string", False, "Run Id"), _c("server_id", "string", True, "ServerId"),
        _c("environment", "string", True, "Environment"), _c("agent_version", "string", True, "Agent Version"),
        _c("agent_instance_id", "string", True, "Agent Instance Id"), _c("started_utc", "timestamp", True, "Started (UTC)"),
        _c("ended_utc", "timestamp", True, "Ended (UTC)"), _c("run_date", "date", True, "Run Date"),
        _c("duration_seconds", "double", True, "Duration (s)"), _c("status", "string", True, "Status"),
        _c("trigger", "string", True, "Trigger"), _c("auth_mode", "string", True, "Auth Mode"),
        _c("files_scanned", "bigint", True, "Files Scanned"), _c("segments_uploaded", "bigint", True, "Segments Uploaded"),
        _c("bytes_uploaded", "bigint", True, "Bytes Uploaded"), _c("errors", "bigint", True, "Errors"),
        _c("warnings", "bigint", True, "Warnings"), _c("issues_summary", "string", True, "Issues"),
    ],
    dedup="Rebuilt every run", retention="gold.ingestionWindowDays", model_table="Agent Runs", source="ops.agent_runs",
)
_table(
    "gold.ingestion_processing_runs", "Notebook runs (new ingestion metric).", "Notebook run", ["run_id"],
    [
        _c("run_id", "string", False, "Run Id"), _c("stage", "string", True, "Stage"),
        _c("notebook", "string", True, "Notebook"), _c("started_utc", "timestamp", True, "Started (UTC)"),
        _c("ended_utc", "timestamp", True, "Ended (UTC)"), _c("run_date", "date", True, "Run Date"),
        _c("duration_seconds", "double", True, "Duration (s)"), _c("status", "string", True, "Status"),
        _c("rows_read", "bigint", True, "Rows Read"), _c("rows_written", "bigint", True, "Rows Written"),
        _c("rows_rejected", "bigint", True, "Rows Rejected"), _c("batch_id", "string", True, "Batch Id"),
        _c("error_message", "string", True, "Error"),
    ],
    dedup="Rebuilt every run", retention="gold.ingestionWindowDays", model_table="Processing Runs",
    source="ops.processing_runs",
)
_table(
    "gold.ingestion_issues", "Quarantined files, rejected records, missing segments, failures and schema drift (new).",
    "Issue", ["issue_id"],
    [
        _c("issue_id", "string", False, "Issue Id"), _c("issue_type", "string", True, "Issue Type"),
        _c("severity", "string", True, "Severity"), _c("detected_utc", "timestamp", True, "Detected (UTC)"),
        _c("detected_date", "date", True, "Detected Date"), _c("server_id", "string", True, "ServerId"),
        _c("gateway_id", "string", True, "GatewayId"), _c("log_type", "string", True, "Log Type"),
        _c("object_path", "string", True, "Object"), _c("reason", "string", True, "Reason"),
        _c("details", "string", True, "Details"), _c("occurrences", "bigint", True, "Occurrences"),
        _c("batch_id", "string", True, "Batch Id"),
    ],
    dedup="Rebuilt every run", retention="gold.ingestionWindowDays", model_table="Ingestion Issues",
    source="ops.rejected_records, ops.quarantined_files, ops.segment_registry, ops.agent_runs, ops.processing_runs, ops.schema_drift",
)

# ----- Ops (internal state) ---------------------------------------------------------------------------------------
_table(
    "ops.manifest_registry", "Manifests seen by the Bronze notebook.", "Manifest file", ["manifest_path"],
    [
        _c("manifest_path", "string", False), _c("run_id", "string"), _c("environment", "string"),
        _c("server_name", "string"), _c("server_id", "string"), _c("agent_instance_id", "string"),
        _c("agent_version", "string"), _c("created_utc", "timestamp"), _c("segment_count", "bigint"),
        _c("status", "string", True, None, "Registered | Invalid"), _c("error", "string"),
        _c("registered_utc", "timestamp"), _c("batch_id", "string"),
    ],
    dedup="MERGE on manifest_path", retention="retention.opsDays",
)
_table(
    "ops.segment_registry", "Every segment listed in a manifest and its ingestion status (processing checkpoint).",
    "Segment", ["segment_id"],
    [
        _c("segment_id", "string", False), _c("manifest_run_id", "string"), _c("manifest_path", "string"),
        _c("raw_path", "string"), _c("log_type", "string"), _c("record_format", "string"),
        _c("environment", "string"), _c("cluster_id", "string"), _c("cluster_name", "string"),
        _c("gateway_id", "string"), _c("gateway_name", "string"), _c("server_name", "string"),
        _c("server_id", "string"), _c("agent_instance_id", "string"), _c("agent_version", "string"),
        _c("source_name", "string"), _c("source_file_name", "string"), _c("source_file_path", "string"),
        _c("source_fingerprint", "string"), _c("source_last_write_utc", "timestamp"),
        _c("offset_start", "bigint"), _c("offset_end", "bigint"), _c("byte_count", "bigint"),
        _c("header_bytes", "bigint"), _c("sha256", "string"), _c("upload_mode", "string"),
        _c("uploaded_utc", "timestamp"),
        _c("status", "string", True, None, "Pending | Processed | Missing | Quarantined"),
        _c("attempts", "int"), _c("record_count", "bigint"), _c("malformed_count", "bigint"),
        _c("first_seen_utc", "timestamp"), _c("processed_utc", "timestamp"), _c("batch_id", "string"),
        _c("error", "string"),
    ],
    dedup="MERGE on segment_id", retention="retention.opsDays",
)
_table(
    "ops.agent_runs", "Agent run telemetry documents.", "Agent run", ["run_id"],
    [
        _c("run_id", "string", False), _c("environment", "string"), _c("server_name", "string"),
        _c("server_id", "string"), _c("server_fqdn", "string"), _c("agent_instance_id", "string"),
        _c("agent_version", "string"), _c("time_zone_id", "string"), _c("utc_offset_minutes", "int"),
        _c("started_utc", "timestamp"), _c("ended_utc", "timestamp"), _c("duration_ms", "bigint"),
        _c("status", "string"), _c("trigger", "string"), _c("auth_mode", "string"), _c("target_type", "string"),
        _c("config_hash", "string"), _c("powershell_version", "string"), _c("os_version", "string"),
        _c("sources_scanned", "bigint"), _c("files_scanned", "bigint"), _c("files_changed", "bigint"),
        _c("segments_uploaded", "bigint"), _c("segments_skipped", "bigint"), _c("bytes_uploaded", "bigint"),
        _c("errors", "bigint"), _c("warnings", "bigint"), _c("gateways_json", "string"),
        _c("issues_json", "string"), _c("telemetry_path", "string"), _c("received_utc", "timestamp"),
    ],
    dedup="MERGE on run_id", retention="retention.opsDays",
)
_table(
    "ops.processing_runs", "Notebook run log.", "Notebook run", ["run_id"],
    [
        _c("run_id", "string", False), _c("stage", "string"), _c("notebook", "string"),
        _c("started_utc", "timestamp"), _c("ended_utc", "timestamp"), _c("status", "string"),
        _c("rows_read", "bigint"), _c("rows_written", "bigint"), _c("rows_rejected", "bigint"),
        _c("batch_id", "string"), _c("parameters_json", "string"), _c("details_json", "string"),
        _c("error_message", "string"), _c("lib_version", "string"),
    ],
    dedup="MERGE on run_id", retention="retention.opsDays",
)
_table(
    "ops.watermarks", "Incremental processing watermarks (processing checkpoints).", "Stage", ["stage"],
    [_c("stage", "string", False), _c("watermark", "string"), _c("updated_utc", "timestamp"), _c("run_id", "string")],
    dedup="MERGE on stage", retention="Permanent",
)
_table(
    "ops.rejected_records", "Records that could not be parsed or validated (raw text preserved).", "Rejected record",
    ["record_id"],
    [
        _c("record_id", "string", False), _c("record_key", "string"), _c("segment_id", "string"),
        _c("log_type", "string"), _c("gateway_id", "string"), _c("server_id", "string"),
        _c("server_name", "string"), _c("stage", "string"), _c("reason", "string"), _c("raw_text", "string"),
        _c("detected_utc", "timestamp"), _c("batch_id", "string"),
    ],
    dedup="MERGE on record_id", retention="retention.opsDays",
)
_table(
    "ops.quarantined_files", "Files that could not be processed (checksum, binary, invalid manifest, orphan).",
    "Quarantined file", ["quarantine_id"],
    [
        _c("quarantine_id", "string", False), _c("segment_id", "string"), _c("original_path", "string"),
        _c("quarantine_path", "string"), _c("reason", "string"), _c("details", "string"),
        _c("detected_utc", "timestamp"), _c("batch_id", "string"), _c("server_name", "string"),
        _c("server_id", "string"), _c("gateway_id", "string"), _c("log_type", "string"),
    ],
    dedup="MERGE on quarantine_id", retention="retention.opsDays",
)
_table(
    "ops.schema_drift", "Columns/fields seen in source files that are not part of the known schema.",
    "Log type × column", ["log_type", "column_name"],
    [
        _c("log_type", "string", False), _c("column_name", "string", False), _c("first_seen_utc", "timestamp"),
        _c("last_seen_utc", "timestamp"), _c("occurrences", "bigint"), _c("sample_value", "string"),
        _c("first_batch_id", "string"),
    ],
    dedup="MERGE on (log_type, column_name)", retention="Permanent",
)


def model_column_map(table_key: str) -> Dict[str, str]:
    """Delta column → semantic-model column for a Gold table."""
    return {c["name"]: c["model"] for c in TABLES[table_key]["columns"] if c.get("model")}


def columns_of(table_key: str) -> List[str]:
    return [c["name"] for c in TABLES[table_key]["columns"]]

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Partition processors — pure Python functions executed on Spark executors (unit-tested locally)
# ---------------------------------------------------------------------------------------------------------------

SILVER_EVENT_TIME_COLUMNS: Dict[str, Tuple[str, ...]] = {
    "gateway_logs": ("event_utc",),
    "artifact_traces": ("event_utc",),
    "query_starts": ("query_start_utc",),
    "query_executions": ("data_processing_end_utc", "query_execution_end_utc", "ingested_utc"),
    "query_aggregations": ("aggregation_end_utc",),
    "system_counters": ("aggregation_end_utc",),
    "mashup_logs": ("start_utc",),
}
SILVER_SNAPSHOT_TABLES = ("mashup_container_profiles", "gateway_metadata", "gateway_cluster_members")
SILVER_LINEAGE_COLUMNS = ("record_key", "record_id", "segment_id", "gateway_id", "cluster_id", "environment",
                          "server_id", "server_name", "log_type", "source_file_name", "record_offset",
                          "ingest_batch_id", "ingested_utc")
_SILVER_COLUMN_CACHE: Dict[str, frozenset] = {}


def _silver_columns(table: str) -> frozenset:
    if table not in _SILVER_COLUMN_CACHE:
        _SILVER_COLUMN_CACHE[table] = frozenset(columns_of(f"silver.{table}"))
    return _SILVER_COLUMN_CACHE[table]


def bronze_rows_for_segment(content: bytes, segment: Dict[str, Any], batch_id: str, ingested_utc: datetime,
                            max_record_chars: int = 1000000) -> Tuple[List[Dict[str, Any]], Dict[str, Any]]:
    """Parse one segment (registry row from ops.segment_registry) into Bronze rows with lineage columns."""
    meta = {
        "segmentId": segment.get("segment_id"), "logType": segment.get("log_type"),
        "format": segment.get("record_format"), "uploadMode": segment.get("upload_mode"),
        "offsetStart": segment.get("offset_start"), "headerBytes": segment.get("header_bytes"),
        "sha256": segment.get("sha256"), "byteCount": segment.get("byte_count"),
        "gatewayId": segment.get("gateway_id"), "sourceFingerprint": segment.get("source_fingerprint"),
    }
    records, result = parse_segment(content, meta, max_record_chars)
    lineage = {
        "environment": segment.get("environment"), "cluster_id": segment.get("cluster_id"),
        "gateway_id": segment.get("gateway_id"), "server_name": segment.get("server_name"),
        "server_id": segment.get("server_id"), "agent_instance_id": segment.get("agent_instance_id"),
        "agent_version": segment.get("agent_version"), "source_name": segment.get("source_name"),
        "source_file_name": segment.get("source_file_name"), "source_file_path": segment.get("source_file_path"),
        "source_fingerprint": segment.get("source_fingerprint"),
        "source_last_write_utc": segment.get("source_last_write_utc"), "raw_path": segment.get("raw_path"),
        "manifest_run_id": segment.get("manifest_run_id"), "uploaded_utc": segment.get("uploaded_utc"),
        "ingest_batch_id": batch_id, "ingested_utc": ingested_utc, "ingest_date": ingested_utc.date(),
    }
    for record in records:
        record.update(lineage)
    return records, result


def silver_rows_for_bronze(bronze: Dict[str, Any], settings: Dict[str, Any], redactor: Optional[Redactor],
                           processed_utc: datetime) -> List[Tuple[str, Dict[str, Any]]]:
    """Bronze record → [(silver table, row)], plus ('_rejected', row) and ('_drift', row) side outputs."""
    try:
        outputs = to_silver_rows(bronze, settings, redactor)
    except Exception as exc:  # any parsing problem → rejected record, never a failed batch
        return [("_rejected", {
            "record_id": bronze.get("record_id"), "record_key": bronze.get("record_key"),
            "segment_id": bronze.get("segment_id"), "log_type": bronze.get("log_type"),
            "gateway_id": bronze.get("gateway_id"), "server_id": bronze.get("server_id"),
            "server_name": bronze.get("server_name"), "stage": "silver",
            "reason": truncate(f"{type(exc).__name__}: {exc}", 2000),
            "raw_text": truncate(bronze.get("record_text"), DIRECT_LAKE_MAX_STRING),
            "detected_utc": processed_utc, "batch_id": bronze.get("ingest_batch_id"),
        })]
    results: List[Tuple[str, Dict[str, Any]]] = []
    per_table_index: Dict[str, int] = {}
    for table, values in outputs:
        row = {column: bronze.get(column) for column in SILVER_LINEAGE_COLUMNS}
        for key, value in values.items():
            if value is not None or key not in row:
                row[key] = value
        index = per_table_index.get(table, 0)
        per_table_index[table] = index + 1
        if index:
            row["record_key"] = sha256_hex(bronze.get("record_key"), index)
        row["processed_utc"] = processed_utc
        if table in SILVER_SNAPSHOT_TABLES:
            row["snapshot_key"] = bronze.get("source_fingerprint")
            row["snapshot_utc"] = bronze.get("source_last_write_utc") or bronze.get("uploaded_utc")
        else:
            moment = next((row.get(c) for c in SILVER_EVENT_TIME_COLUMNS.get(table, ()) if row.get(c)), None)
            moment = moment or bronze.get("ingested_utc")
            row["event_date"] = moment.date() if moment else None
            row["event_month"] = event_month_of(moment)
        results.append((table, {k: v for k, v in row.items() if k in _silver_columns(table)}))
        extra = row.get("extra_columns")
        if extra:
            try:
                for name, sample in json.loads(extra).items():
                    if not str(name).startswith("_"):
                        results.append(("_drift", {
                            "log_type": bronze.get("log_type"), "column_name": str(name)[:256],
                            "sample_value": truncate(None if sample is None else str(sample), 200),
                            "batch_id": bronze.get("ingest_batch_id"),
                        }))
            except ValueError:
                pass
    return results


def cap_string(value: Optional[str], limit: int = DIRECT_LAKE_MAX_STRING) -> Optional[str]:
    return truncate(value, limit)


RAW_PATH_RE = re.compile(
    r"^raw/environment=[a-z0-9._-]+/cluster=[a-z0-9._-]+/gateway=[a-z0-9._-]+/server=[a-z0-9._-]+/"
    r"log-type=[a-z0-9-]+/year=\d{4}/month=\d{2}/day=\d{2}/(?!\.{1,2}$)[A-Za-z0-9._-]+$"
)
MANIFEST_SEGMENT_REQUIRED = (
    "segmentId", "path", "logType", "format", "uploadMode", "sourceName", "sourceFileName", "sourceFingerprint",
    "offsetStart", "offsetEnd", "byteCount", "headerBytes", "sha256", "uploadedUtc", "gatewayId",
)


def validate_manifest(document: Any) -> List[str]:
    """Structural validation of an agent manifest (the document written by the agent's Manifest.ps1)."""
    if not isinstance(document, dict):
        return ["manifest is not a JSON object"]
    errors: List[str] = []
    if document.get("documentType") != "gwmon.manifest":
        errors.append("documentType must be 'gwmon.manifest'")
    if not str(document.get("schemaVersion", "")).startswith("1."):
        errors.append(f"unsupported schemaVersion '{document.get('schemaVersion')}'")
    for key in ("runId", "createdUtc", "environment", "agent", "segments"):
        if key not in document:
            errors.append(f"missing '{key}'")
    agent = document.get("agent") if isinstance(document.get("agent"), dict) else {}
    for key in ("instanceId", "version", "serverName", "serverId"):
        if not agent.get(key):
            errors.append(f"missing agent.{key}")
    segments = document.get("segments")
    if not isinstance(segments, list):
        errors.append("segments must be an array")
        return errors
    for index, segment in enumerate(segments):
        if not isinstance(segment, dict):
            errors.append(f"segments[{index}] is not an object")
            continue
        missing = [key for key in MANIFEST_SEGMENT_REQUIRED if key not in segment]
        if missing:
            errors.append(f"segments[{index}] missing {missing}")
        elif segment["logType"] not in LOG_TYPES:
            errors.append(f"segments[{index}] unknown logType '{segment['logType']}'")
        elif not RAW_PATH_RE.match(str(segment["path"])):
            errors.append(f"segments[{index}] invalid path '{segment['path']}'")
        elif int(segment["offsetEnd"]) < int(segment["offsetStart"]):
            errors.append(f"segments[{index}] offsetEnd < offsetStart")
        if len(errors) >= 20:
            errors.append("too many errors")
            break
    return errors


def manifest_registry_rows(document: Dict[str, Any], manifest_path: str, landing_root: str, batch_id: str,
                           now: datetime) -> Tuple[Dict[str, Any], List[Dict[str, Any]]]:
    """Map a valid manifest to one ops.manifest_registry row and ops.segment_registry rows (status Pending)."""
    agent = document["agent"]
    manifest_row = {
        "manifest_path": manifest_path, "run_id": document["runId"], "environment": document["environment"],
        "server_name": agent["serverName"], "server_id": agent["serverId"], "agent_instance_id": agent["instanceId"],
        "agent_version": agent["version"], "created_utc": parse_utc(document.get("createdUtc")),
        "segment_count": len(document["segments"]), "status": "Registered", "error": None,
        "registered_utc": now, "batch_id": batch_id,
    }
    segments = []
    for segment in document["segments"]:
        segments.append({
            "segment_id": str(segment["segmentId"]).lower(), "manifest_run_id": document["runId"],
            "manifest_path": manifest_path, "raw_path": f"{landing_root}/{segment['path']}",
            "log_type": segment["logType"], "record_format": segment["format"],
            "environment": document["environment"], "cluster_id": lower_id(segment.get("clusterId")),
            "cluster_name": clean_text(segment.get("clusterName")), "gateway_id": lower_id(segment["gatewayId"]),
            "gateway_name": clean_text(segment.get("gatewayName")), "server_name": agent["serverName"],
            "server_id": agent["serverId"], "agent_instance_id": agent["instanceId"], "agent_version": agent["version"],
            "source_name": segment.get("sourceName"), "source_file_name": segment.get("sourceFileName"),
            "source_file_path": segment.get("sourceFilePath"), "source_fingerprint": segment.get("sourceFingerprint"),
            "source_last_write_utc": parse_utc(segment.get("sourceLastWriteUtc")),
            "offset_start": int(segment["offsetStart"]), "offset_end": int(segment["offsetEnd"]),
            "byte_count": int(segment["byteCount"]), "header_bytes": int(segment["headerBytes"]),
            "sha256": str(segment["sha256"]).lower(), "upload_mode": segment.get("uploadMode"),
            "uploaded_utc": parse_utc(segment.get("uploadedUtc")), "status": "Pending", "attempts": 0,
            "record_count": None, "malformed_count": None, "first_seen_utc": now, "processed_utc": None,
            "batch_id": None, "error": None,
        })
    return manifest_row, segments


def agent_run_row(document: Dict[str, Any], telemetry_path: str, now: datetime) -> Dict[str, Any]:
    """Map a run telemetry document (gwmon.run) to an ops.agent_runs row."""
    if not isinstance(document, dict) or document.get("documentType") != "gwmon.run":
        raise ValueError("not a gwmon.run document")
    agent = document.get("agent") or {}
    counts = document.get("counts") or {}
    started, ended = parse_utc(document.get("startedUtc")), parse_utc(document.get("endedUtc"))
    if not document.get("runId") or started is None:
        raise ValueError("missing runId or startedUtc")
    duration = document.get("durationMs")
    if duration is None and started and ended:
        duration = int((ended - started).total_seconds() * 1000)
    return {
        "run_id": str(document["runId"]).lower(), "environment": document.get("environment"),
        "server_name": agent.get("serverName"), "server_id": agent.get("serverId"),
        "server_fqdn": agent.get("serverFqdn"), "agent_instance_id": agent.get("instanceId"),
        "agent_version": agent.get("version"), "time_zone_id": agent.get("timeZoneId"),
        "utc_offset_minutes": parse_int(agent.get("utcOffsetMinutes")), "started_utc": started, "ended_utc": ended,
        "duration_ms": parse_int(duration), "status": document.get("status"), "trigger": document.get("trigger"),
        "auth_mode": document.get("authMode"), "target_type": document.get("targetType"),
        "config_hash": document.get("configHash"), "powershell_version": document.get("powershellVersion"),
        "os_version": document.get("osVersion"), "sources_scanned": parse_int(counts.get("sourcesScanned")),
        "files_scanned": parse_int(counts.get("filesScanned")), "files_changed": parse_int(counts.get("filesChanged")),
        "segments_uploaded": parse_int(counts.get("segmentsUploaded")),
        "segments_skipped": parse_int(counts.get("segmentsSkipped")),
        "bytes_uploaded": parse_int(counts.get("bytesUploaded")), "errors": parse_int(counts.get("errors")),
        "warnings": parse_int(counts.get("warnings")),
        "gateways_json": truncate(compact_json(document.get("gateways") or []), 30000),
        "issues_json": truncate(compact_json(document.get("issues") or []), 30000),
        "telemetry_path": telemetry_path, "received_utc": now,
    }

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

# CELL ********************

# ---------------------------------------------------------------------------------------------------------------
# Spark / Delta helpers (executed inside Fabric only; local unit tests never call them)
# ---------------------------------------------------------------------------------------------------------------

try:
    from pyspark.sql import functions as F
    from pyspark.sql import types as T
    from pyspark.sql.window import Window  # noqa: F401  (used by nb_gwmon_ingest through %run)
    PYSPARK_AVAILABLE = True
except ImportError:  # local unit tests
    PYSPARK_AVAILABLE = False


def get_spark():
    session = globals().get("spark")
    if session is None:
        from pyspark.sql import SparkSession
        session = SparkSession.builder.getOrCreate()
    return session


def nbutils():
    """notebookutils (current runtimes) or mssparkutils (older runtimes)."""
    for name in ("notebookutils", "mssparkutils"):
        module = globals().get(name)
        if module is not None:
            return module
    try:
        import notebookutils as module  # type: ignore
        return module
    except ImportError:
        from notebookutils import mssparkutils as module  # type: ignore
        return module


def configure_spark(layer: str) -> None:
    """Session settings: UTC, proleptic calendar for 1899 time-of-day values, optimize write, V-Order on Gold."""
    session = get_spark()
    settings = {
        "spark.sql.session.timeZone": "UTC",
        "spark.sql.parquet.int96RebaseModeInWrite": "CORRECTED",
        "spark.sql.parquet.datetimeRebaseModeInWrite": "CORRECTED",
        "spark.sql.parquet.int96RebaseModeInRead": "CORRECTED",
        "spark.sql.parquet.datetimeRebaseModeInRead": "CORRECTED",
        "spark.microsoft.delta.optimizeWrite.enabled": "true",
        "spark.databricks.delta.optimizeWrite.enabled": "true",
        "spark.sql.parquet.vorder.default": "true" if layer == "gold" else "false",
        "spark.sql.parquet.vorder.enabled": "true" if layer == "gold" else "false",
    }
    for key, value in settings.items():
        try:
            session.conf.set(key, value)
        except Exception as exc:  # some keys do not exist on every runtime
            print(f"[gwmon] could not set {key}: {exc}")


def spark_type(name: str):
    mapping = {
        "string": T.StringType(), "bigint": T.LongType(), "int": T.IntegerType(), "double": T.DoubleType(),
        "boolean": T.BooleanType(), "date": T.DateType(), "timestamp": T.TimestampType(),
    }
    return mapping[name]


def spark_schema(table_key: str):
    return T.StructType([T.StructField(c["name"], spark_type(c["type"]), c["nullable"])
                         for c in TABLES[table_key]["columns"]])


def table_properties(layer: str) -> Dict[str, str]:
    if layer == "gold":
        return {"delta.parquet.vorder.enabled": "true", "delta.autoOptimize.optimizeWrite": "true"}
    return {"delta.autoOptimize.optimizeWrite": "true", "delta.autoOptimize.autoCompact": "true"}


def _sql_string(value: str) -> str:
    return "'" + str(value).replace("\\", "\\\\").replace("'", "\\'") + "'"


def create_table_sql(table_key: str) -> str:
    table = TABLES[table_key]
    columns = ",\n  ".join(
        f"`{c['name']}` {c['type'].upper()}{'' if c['nullable'] else ' NOT NULL'} COMMENT {_sql_string(c['description'] or c['model'] or c['name'])}"
        for c in table["columns"]
    )
    partition = f"\nPARTITIONED BY ({', '.join(table['partition_by'])})" if table["partition_by"] else ""
    properties = ", ".join(f"{_sql_string(k)} = {_sql_string(v)}" for k, v in table_properties(table["layer"]).items())
    return (f"CREATE TABLE IF NOT EXISTS {table['layer']}.{table['name']} (\n  {columns}\n) USING DELTA{partition}\n"
            f"COMMENT {_sql_string(table['description'])}\nTBLPROPERTIES ({properties})")


def ensure_schemas() -> None:
    for schema in SCHEMAS:
        get_spark().sql(f"CREATE SCHEMA IF NOT EXISTS {schema}")


def ensure_table(table_key: str) -> List[str]:
    """Create the table if needed and add any column missing from the contract (additive evolution only)."""
    session = get_spark()
    session.sql(create_table_sql(table_key))
    existing = {f.name.lower() for f in session.table(table_key).schema.fields}
    added = []
    for column in TABLES[table_key]["columns"]:
        if column["name"].lower() not in existing:
            session.sql(f"ALTER TABLE {table_key} ADD COLUMNS (`{column['name']}` {column['type'].upper()} "
                        f"COMMENT {_sql_string(column['description'] or column['name'])})")
            added.append(column["name"])
    return added


def ensure_all_tables() -> Dict[str, List[str]]:
    ensure_schemas()
    return {key: ensure_table(key) for key in TABLES}


def ensure_all_tables_if_needed() -> Optional[Dict[str, List[str]]]:
    """Run ensure_all_tables only when a contract changed or a table is missing (saves ~35 catalog calls per run).

    The fingerprint of the contracts is kept in ops.watermarks (stage 'schema'). Returns None when nothing was needed.
    """
    fingerprint = f"{GWMON_LIB_VERSION}:{sha256_hex(compact_json(TABLES))}"
    session = get_spark()
    try:
        existing = {f"{schema}.{row['tableName']}".lower()
                    for schema in SCHEMAS for row in session.sql(f"SHOW TABLES IN {schema}").collect()}
        current = get_watermark("schema")
    except Exception:  # first run: schemas or ops.watermarks don't exist yet
        existing, current = set(), None
    if current == fingerprint and all(key.lower() in existing for key in TABLES):
        return None
    added = ensure_all_tables()
    set_watermark("schema", fingerprint)
    return added


def conform(df, table_key: str):
    """Select the contract columns in order, casting types and adding missing columns as nulls."""
    present = {name.lower(): name for name in df.columns}
    selected = []
    for column in TABLES[table_key]["columns"]:
        source = present.get(column["name"].lower())
        expression = F.col(f"`{source}`") if source else F.lit(None)
        selected.append(expression.cast(spark_type(column["type"])).alias(column["name"]))
    return df.select(*selected)


def to_df(rows: Sequence[Dict[str, Any]], table_key: str):
    names = columns_of(table_key)
    return get_spark().createDataFrame([tuple(row.get(name) for name in names) for row in rows], spark_schema(table_key))


def _temp_view(df) -> str:
    name = "_gwmon_" + uuid.uuid4().hex[:12]
    df.createOrReplaceTempView(name)
    return name


def merge_insert_only(df, table_key: str, keys: Sequence[str], target_filter: Optional[str] = None) -> None:
    """Insert rows whose keys are not already present (idempotent append)."""
    view = _temp_view(conform(df, table_key))
    condition = " AND ".join(f"t.`{k}` <=> s.`{k}`" for k in keys)
    if target_filter:
        condition += f" AND ({target_filter})"
    get_spark().sql(f"MERGE INTO {table_key} AS t USING {view} AS s ON {condition} WHEN NOT MATCHED THEN INSERT *")


def merge_upsert(df, table_key: str, keys: Sequence[str], target_filter: Optional[str] = None) -> None:
    view = _temp_view(conform(df, table_key))
    condition = " AND ".join(f"t.`{k}` <=> s.`{k}`" for k in keys)
    if target_filter:
        condition += f" AND ({target_filter})"
    get_spark().sql(f"MERGE INTO {table_key} AS t USING {view} AS s ON {condition} "
                    f"WHEN MATCHED THEN UPDATE SET * WHEN NOT MATCHED THEN INSERT *")


def replace_partitions(df, table_key: str, column: str, values: Iterable[Any]) -> int:
    """Atomically replace the given partition values (idempotent recomputation)."""
    distinct_values = sorted({int(v) for v in values if v is not None})
    if not distinct_values:
        return 0
    predicate = f"{column} IN ({', '.join(str(v) for v in distinct_values)})"
    (conform(df, table_key).where(predicate)
        .write.format("delta").mode("overwrite").option("replaceWhere", predicate).saveAsTable(table_key))
    return len(distinct_values)


def overwrite_table(df, table_key: str) -> None:
    conform(df, table_key).write.format("delta").mode("overwrite").saveAsTable(table_key)


def cap_strings(df, limit: int = DIRECT_LAKE_MAX_STRING):
    """Truncate every string column to the Direct Lake limit (applied to all Gold writes)."""
    columns = []
    for field in df.schema.fields:
        if isinstance(field.dataType, T.StringType):
            columns.append(F.substring(F.col(f"`{field.name}`"), 1, limit).alias(field.name))
        else:
            columns.append(F.col(f"`{field.name}`"))
    return df.select(*columns)


def get_watermark(stage: str) -> Optional[str]:
    rows = get_spark().sql(f"SELECT watermark FROM ops.watermarks WHERE stage = {_sql_string(stage)}").collect()
    return rows[0]["watermark"] if rows else None


def set_watermark(stage: str, value: Optional[str], run_id: Optional[str] = None) -> None:
    if value is None:
        return
    merge_upsert(to_df([{"stage": stage, "watermark": value, "updated_utc": utc_now(), "run_id": run_id}], "ops.watermarks"),
                 "ops.watermarks", ["stage"])


class ProcessingRun:
    """Context manager recording a notebook run in ops.processing_runs (also on failure)."""

    def __init__(self, stage: str, notebook: str, batch_id: Optional[str] = None,
                 parameters: Optional[Dict[str, Any]] = None):
        self.run_id = str(uuid.uuid4())
        self.stage = stage
        self.notebook = notebook
        self.batch_id = batch_id
        self.parameters = parameters or {}
        self.started = utc_now()
        self.metrics = {"rows_read": 0, "rows_written": 0, "rows_rejected": 0}
        self.details: Dict[str, Any] = {}
        self.error: Optional[str] = None

    def _write(self, status: str) -> None:
        row = {
            "run_id": self.run_id, "stage": self.stage, "notebook": self.notebook, "started_utc": self.started,
            "ended_utc": None if status == "Running" else utc_now(), "status": status,
            "rows_read": self.metrics["rows_read"], "rows_written": self.metrics["rows_written"],
            "rows_rejected": self.metrics["rows_rejected"], "batch_id": self.batch_id,
            "parameters_json": compact_json(self.parameters), "details_json": truncate(compact_json(self.details), 30000),
            "error_message": truncate(self.error, 4000), "lib_version": GWMON_LIB_VERSION,
        }
        merge_upsert(to_df([row], "ops.processing_runs"), "ops.processing_runs", ["run_id"])

    def __enter__(self) -> "ProcessingRun":
        self._write("Running")
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc is not None:
            self.error = f"{exc_type.__name__}: {exc}"
        try:
            self._write("Succeeded" if exc is None else "Failed")
        except Exception as write_error:  # never hide the original failure
            print(f"[gwmon] could not record run status: {write_error}")
        return False

    def summary(self) -> Dict[str, Any]:
        return {"run_id": self.run_id, "stage": self.stage, "batch_id": self.batch_id, **self.metrics,
                "details": self.details}


def mount_path(relative: str) -> str:
    return os.path.join(LAKEHOUSE_MOUNT, relative.replace("/", os.sep))


def read_json_relative(relative: str) -> Any:
    with open(mount_path(relative), "r", encoding="utf-8-sig") as handle:
        return json.load(handle)


def _date_partition_dirs(base: str, lookback_days: int, today: Optional[date] = None) -> List[str]:
    """year=/month=/day= folders for the last ``lookback_days`` days below every environment=/server= folder."""
    today = today or utc_now().date()
    results: List[str] = []
    if not os.path.isdir(base):
        return results
    days = [today - timedelta(days=offset) for offset in range(lookback_days + 1)]
    for environment in sorted(os.listdir(base)):
        env_dir = os.path.join(base, environment)
        if not environment.startswith("environment=") or not os.path.isdir(env_dir):
            continue
        for server in sorted(os.listdir(env_dir)):
            server_dir = os.path.join(env_dir, server)
            if not server.startswith("server=") or not os.path.isdir(server_dir):
                continue
            for day in days:
                folder = os.path.join(server_dir, f"year={day:%Y}", f"month={day:%m}", f"day={day:%d}")
                if os.path.isdir(folder):
                    results.append(folder)
    return results


def list_landing_documents(landing_root: str, kind: str, suffix: str, lookback_days: int) -> List[str]:
    """Relative paths of manifests (kind='manifests') or telemetry documents (kind='telemetry')."""
    base = mount_path(f"{landing_root}/{kind}")
    found: List[str] = []
    for folder in _date_partition_dirs(base, lookback_days):
        for name in sorted(os.listdir(folder)):
            if name.endswith(suffix):
                full = os.path.join(folder, name)
                relative = os.path.relpath(full, LAKEHOUSE_MOUNT).replace(os.sep, "/")
                found.append(relative)
    return found


def exit_notebook(value: Dict[str, Any]) -> None:
    text = compact_json(value)
    print(text)
    nbutils().notebook.exit(text)

# METADATA ********************

# META {
# META   "language": "python",
# META   "language_group": "synapse_pyspark"
# META }

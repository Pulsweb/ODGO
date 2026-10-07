# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
The agent module and the notebook library carry the same version.

## [Unreleased]

First public version of ODGO (On-premises Data Gateway Observability), planned as **1.0.0**. It modernizes
[pbigtwmonitor](https://github.com/RuiRomano/pbigtwmonitor) by Rui Romano for Microsoft Fabric.

### Added

* **Setup notebook** `fabric/ODGO_Setup.ipynb`: imported and run in a Fabric workspace, it creates or upgrades the
  lakehouse, the notebooks and their schedules, the semantic model and the report, then prints the agent install
  command, completed with the app registration it finds in the workspace's **Manage access**.
* **Gateway agent** (PowerShell 7 module and scripts):
  * record-aligned incremental segments for all 12 gateway log types;
  * crash-safe commit protocol (journal, staging and rename, manifest, checkpoint) with idempotent uploads;
  * app registration client secret stored encrypted with DPAPI, or managed identity (Azure VM, Azure Arc-enabled
    server detected automatically);
  * `Install-Agent.ps1`: one command that installs or upgrades the agent, writes its configuration, stores the
    secret, registers the scheduled task and tests the connection;
  * `Invoke-GatewayLogCollection.ps1 -Test` and `-PlanOnly`, multiple gateways per server, telemetry outbox.
* **Lakehouse processing:** `nb_gwmon_lib` (table contracts and logic), `nb_gwmon_ingest` (Bronze, Silver and Gold,
  every 6 hours) and `nb_gwmon_maintenance` (retention, `OPTIMIZE`/`VACUUM` and validation, once a day), with manifest
  and checksum validation, quarantine, redaction, schema-drift capture and ingestion-health tables.
* **Semantic model** in TMDL, Direct Lake on OneLake: every original table, column, measure and relationship, plus
  five ingestion-health tables, 10 relationships and 28 *Ingestion Health* measures (67 measures in total).
* **Report** in PBIR: the 13 original pages with their drillthrough and tooltip bindings, new *Ingestion Health* and
  *Ingestion Details* pages, Environment and Server report filters, and a theme instead of background images.

### Changed (compared with pbigtwmonitor)

* Storage moves from an ADLS Gen2 account with a SAS token to OneLake with Microsoft Entra authentication.
* Power Query transformations inside the model are replaced by Spark notebooks. The model reads Gold Delta tables
  in Direct Lake mode.
* The `Requests` calculated table and the calculated columns are materialized in Gold.
* Stale query names in the report are normalized. Orphan bookmarks are removed.

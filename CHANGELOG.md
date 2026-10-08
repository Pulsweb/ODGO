# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).
The agent module and the notebook library carry the same version.

## [Unreleased]

First public version of ODGO (On-premises Data Gateway Observability), planned as **1.0.0**. It modernizes
[pbigtwmonitor](https://github.com/RuiRomano/pbigtwmonitor) by Rui Romano for Microsoft Fabric.

### Added

* **Setup notebook** `fabric/ODGO_Setup.ipynb`: imported and run in a Fabric workspace, it creates or upgrades the
  lakehouse `ODGO_Lakehouse`, the notebooks and their schedules, the semantic model and the report in a minute or two,
  starts the first ingestion in the background, then prints the agent install command. Every Fabric item it creates
  starts with `ODGO_`.
* **Gateway agent** (PowerShell module and scripts for Windows PowerShell 5.1 and PowerShell 7; the scheduled task
  uses the Windows PowerShell built into Windows, so the servers need nothing else):
  * record-aligned incremental segments for all 12 gateway log types;
  * crash-safe commit protocol (journal, staging and rename, manifest, checkpoint) with idempotent uploads;
  * app registration client secret stored encrypted with DPAPI, or managed identity (Azure VM, Azure Arc-enabled
    server detected automatically);
  * `Install-Agent.ps1`: one command, which can be pasted in Windows PowerShell or PowerShell 7, that installs or
    upgrades the agent in one folder of your choice (`-InstallPath`) with its configuration, secret, state and logs,
    registers the scheduled task and tests the connection;
  * `Invoke-GatewayLogCollection.ps1 -Test` and `-PlanOnly`, multiple gateways per server, telemetry outbox.
* **Lakehouse processing:** `ODGO_Lib` (table contracts and logic), `ODGO_Ingest` (Bronze, Silver and Gold, every
  2 hours) and `ODGO_Maintenance` (retention, `OPTIMIZE`/`VACUUM` and validation, once a day), with manifest and
  checksum validation, quarantine, redaction, schema-drift capture and ingestion-health tables.
* **Semantic model** `ODGO_Model` in TMDL, Direct Lake on OneLake: every original table, column, measure and
  relationship, plus five ingestion-health tables, 10 relationships and 28 *Ingestion Health* measures (67 measures in
  total).
* **Report** `ODGO_Report` in PBIR, with the ODGO logo and theme: a home page with the architecture and the analysis
  paths, then *Overview*, *Requests*, *Queries*, *Logs*, *Mashup*, *System Counters* and *Ingestion Health* pages with
  a filter panel whose date and gateway selections follow you from page to page, plus the query drillthrough and
  tooltips of the original report. Its layout is inspired by FUAM.

### Changed (compared with pbigtwmonitor)

* Storage moves from an ADLS Gen2 account with a SAS token to OneLake with Microsoft Entra authentication.
* Power Query transformations inside the model are replaced by Spark notebooks. The model reads Gold Delta tables
  in Direct Lake mode.
* The `Requests` calculated table and the calculated columns are materialized in Gold.
* The original report is replaced by `ODGO_Report`, which has a new layout and keeps its query drillthrough and
  tooltip pages.

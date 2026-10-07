# Contributing to ODGO

Contributions are welcome: bug reports, new gateway log formats, report improvements, documentation and code.

## Code of conduct

Be respectful, constructive and inclusive, in the spirit of the
[Contributor Covenant](https://www.contributor-covenant.org/version/2/1/code_of_conduct/). Harassment, insults and
personal attacks aren't tolerated; maintainers may edit or remove contributions that don't follow these rules. To
report a conduct problem privately, contact the repository owners through GitHub.

## Before you start

* Report bugs and propose features with the [issue templates](https://github.com/Pulsweb/ODGO/issues/new/choose).
  For larger changes, open an issue first to agree on the approach.
* Never include real gateway logs, tenant IDs, tokens or secrets in issues, commits or pull requests. Remove
  identifiers and sensitive values from any log lines you share. Report security vulnerabilities privately, with
  **Report a vulnerability** in the repository's **Security** tab, not in a public issue.
* Keep the scope in mind: on-premises data gateways (not VNet data gateways), batch-oriented historical analysis in
  Fabric, and an installation that stays simple: one setup notebook and one agent installer.

## Testing your change

The maintainers run an offline test suite (agent, processing library, setup notebook, semantic model and report)
before merging; it isn't published in this repository. In your pull request, describe how you tested your change:

* **Agent:** on a test gateway server, install your version with `Install-Agent.ps1`, then run
  `Invoke-GatewayLogCollection.ps1 -Test` and `-PlanOnly`. To test without Fabric, set `target.type` to `LocalFolder`
  (with `target.localPath`) and `authentication.mode` to `None` in the configuration: the agent then writes the
  landing layout to a local folder.
* **Notebooks, semantic model and report:** in a test workspace, run the setup notebook with `source` set to the
  archive of your branch, for example `https://github.com/<you>/ODGO/archive/refs/heads/<branch>.zip`.
  To edit the model and report, open them in Power BI Desktop as a PBIP project.

## Conventions

### PowerShell

* Modules use `Set-StrictMode -Version 3.0` and `$ErrorActionPreference = 'Stop'`. Agent functions are prefixed
  `Gwm`.
* Functions that return collections emit them on the pipeline; callers wrap the call in `@()`. Don't use
  `return , $array` for public functions.
* Don't assign `if` expressions that output `byte[]`: they're enumerated into `object[]`.
* Agent configuration keys are camelCase and validated, so unknown keys are rejected. Give every new key a default
  and document it in [docs/configuration.md](docs/configuration.md).
* No secrets in configuration or code. No new external module dependency on gateway servers.

### Notebooks

* Keep the Fabric Git source format (`notebook-content.py` with `# CELL` / `# METADATA` markers).
* Put logic in pure-Python functions of `nb_gwmon_lib` so it can be unit-tested without Spark.
* Table changes are additive: `nb_gwmon_ingest` adds new tables and columns on its next run. Update the contract in
  `TABLES`, and the TMDL model if the table is in Gold. The maintainers regenerate
  [docs/data-model.md](docs/data-model.md).
* `fabric/ODGO_Setup.ipynb` keeps its parameters cell first and its run cell last. Increase `SETUP_VERSION` when the
  setup logic changes, so that older copies ask users to import the new one.

### Semantic model and report

* Keep the original object names. New measures go in the *Ingestion Health* display folder, with a description.
* Edit the TMDL and PBIR files in Power BI Desktop (PBIP format) or as text.

### Commits and pull requests

* One topic per pull request, with the documentation updated in the same change.
* Describe user-visible changes in [CHANGELOG.md](CHANGELOG.md) under *Unreleased*.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).

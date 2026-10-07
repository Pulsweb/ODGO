# Setup

ODGO is installed in four steps:

1. [Create an identity for the agents](#1-create-an-identity-for-the-agents) in Microsoft Entra ID.
2. [Give it access to the workspace](#2-give-the-identity-access-to-the-workspace), **before** you run the setup
   notebook.
3. [Run the setup notebook](#3-run-the-setup-notebook) in the workspace.
4. [Install the agent](#4-install-the-agent-on-each-gateway-server) on each gateway server.

Upgrades run steps 3 and 4 again: see [Upgrade](#upgrade).

## Prerequisites

| Where | Requirement |
|---|---|
| Fabric workspace | A workspace assigned to a Fabric capacity (F SKU or trial), preferably used only for ODGO, and the Admin or Member role on it |
| Fabric tenant settings | *Users can access data stored in OneLake with apps external to Fabric* (OneLake settings) and *Service principals can use Fabric APIs* (Developer settings). Both can be limited to a security group that contains the agent identity. See [tenant settings](https://learn.microsoft.com/fabric/admin/about-tenant-settings) |
| Gateway servers | Windows, On-premises data gateway in standard mode, [PowerShell 7.2 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), outbound HTTPS (443) to `login.microsoftonline.com` and `onelake.dfs.fabric.microsoft.com` |
| Report | The *Logs* page uses the AppSource *Text Filter* visual, which your tenant must allow |

## 1. Create an identity for the agents

**App registration with a client secret** (works on any server):

1. In the [Microsoft Entra admin center](https://entra.microsoft.com), open **App registrations** > **New registration**.
   Name it, for example, `odgo-gateway-agent`, keep *Single tenant* and select **Register**. This also creates its
   *Enterprise application* (service principal), which is what you add to the workspace in step 2.
2. Open **Certificates & secrets** > **New client secret**, choose an expiry and copy the secret **Value** (not the
   *Secret ID*). It's shown only once; you type it on each gateway server in step 4.

No API permission is needed: the agents get access through their workspace role (step 2). One app registration can
serve every gateway server. Plan the secret rotation before it expires ([operations.md](operations.md#agent)).

**Managed identity** (no secret): on an Azure VM or an [Azure Arc-enabled server](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication),
use the server's system-assigned managed identity, which has the server's name. Each server has its own identity.

## 2. Give the identity access to the workspace

Do this **before** you run the setup notebook. The agents need the **Contributor** role on the workspace to write
their logs to the lakehouse, and the setup notebook reads the workspace's access list to complete the install command
that it prints.

In the Fabric workspace, select **Manage access** > **Add people or groups**, type the name of the app registration
(for example `odgo-gateway-agent`), select it, choose **Contributor** and select **Add**. With managed identities, add
the identity of each server the same way (it has the server's name), or a security group that contains them.

Contributor is enough. Don't give the agents the Admin or Member role: anyone who holds the client secret could then
manage the access to the workspace.

## 3. Run the setup notebook

1. Download [fabric/ODGO_Setup.ipynb](../fabric/ODGO_Setup.ipynb).
2. In the Fabric workspace, select **Import** > **Notebook** > **From this computer** and select the file.
3. Open the notebook and select **Run all**. You don't need to change its parameters
   ([configuration.md](configuration.md#setup-notebook-parameters)). In a few minutes the notebook:
   * creates the lakehouse `lh_gateway_monitor` (with schemas);
   * imports the notebooks `nb_gwmon_lib`, `nb_gwmon_ingest` and `nb_gwmon_maintenance`, attached to the lakehouse;
   * runs `nb_gwmon_ingest` once, which creates the tables, the landing folder and `processing.json`;
   * creates the *Gateway Monitor* semantic model (Direct Lake) and report;
   * schedules `nb_gwmon_ingest` every 6 hours and `nb_gwmon_maintenance` once a day.
4. The last cell prints the PowerShell lines for step 4. They contain the IDs of your workspace, lakehouse and tenant,
   and the Application (client) ID of the app registration that the notebook found in **Manage access**. If the
   command ends with `-ClientId <client-id>`, no app registration was found: do step 2 and run the notebook again.

The notebook downloads the ODGO version set in `source` (by default the `main` branch on GitHub).

## 4. Install the agent on each gateway server

Open PowerShell 7 **as administrator** on the gateway server and paste the lines printed by the setup notebook:

```powershell
Invoke-WebRequest 'https://github.com/Pulsweb/ODGO/archive/refs/heads/main.zip' -OutFile odgo.zip
Remove-Item odgo -Recurse -Force -ErrorAction Ignore; Expand-Archive odgo.zip odgo
$installer = (Get-ChildItem odgo -Recurse -Filter Install-Agent.ps1 | Select-Object -First 1).FullName
& $installer -InstallPath "$env:ProgramFiles\ODGO" -WorkspaceId <workspace-id> -LakehouseId <lakehouse-id> -TenantId <tenant-id> -ClientId <client-id>
```

`-InstallPath` is the folder of the agent: change it to install the agent elsewhere, for example `D:\ODGO`. Use a new
or empty local folder, not the root of a drive or a network path.

You're prompted for the client secret value (input hidden). With a managed identity, replace `-TenantId … -ClientId …`
with `-ManagedIdentity` (the notebook prints that line too).

The installer:

* copies the agent to the `-InstallPath` folder, which only SYSTEM and Administrators can change because the agent
  runs as SYSTEM;
* writes `%ProgramData%\ODGO\config\config.json` and stores the client secret encrypted with DPAPI;
  only SYSTEM and Administrators can open this folder;
* registers the scheduled task `\ODGO\Collect Gateway Logs`, which runs every 15 minutes as SYSTEM;
* tests the configuration, gateway discovery, authentication and write access to OneLake. Each check prints *PASS*,
  *WARNING* or *FAIL*, with a fix for each warning or failure.

The first upload starts about 2 minutes later. The server appears on the *Ingestion Health* page of the report after
the next `nb_gwmon_ingest` run, within 6 hours by default. To see it sooner, run `nb_gwmon_ingest` yourself from the
workspace.

Optional parameters: `-ProxyUrl` (outbound proxy), `-IntervalMinutes`, `-TaskUser` (a group managed service account
instead of SYSTEM) and `-SkipTest`. Run `Get-Help $installer -Detailed` for details.

**Server without internet access:** download the zip on another computer, copy it to the server, extract it, unblock
the files (`Get-ChildItem -Recurse | Unblock-File`) and run `gateway-agent\Install-Agent.ps1` with the same
parameters. The server still needs HTTPS access to Microsoft Entra ID and OneLake, directly or through `-ProxyUrl`.

## Share the report

The semantic model reads the lakehouse with the identity of each report reader (single sign-on), so readers need read
access to the lakehouse data. To let readers open the report without that access, bind the model to a fixed
identity:

1. Open the settings of the *Gateway Monitor* semantic model > **Gateway and cloud connections**.
2. Create a cloud connection for the OneLake data source with an identity that can read the lakehouse (for example
   the [workspace identity](https://learn.microsoft.com/fabric/security/workspace-identity) or a service principal),
   with single sign-on turned off, and map the data source to it.

Then give readers the Viewer role on the workspace, or share the report with them.

## Upgrade

1. Run the setup notebook again. It downloads the version set in `source` and updates the items in place; data is
   kept. If that version ships a newer setup notebook, the output asks you to import it and run it instead.
2. On each gateway server, run the `Install-Agent.ps1` of the new version without parameters (the download lines
   of step 4, then `& $installer`). It finds the existing installation, replaces the agent files in its folder and
   keeps the configuration, secret, state and scheduled task.

## Uninstall

* Agent: run `Uninstall-Agent.ps1` from the agent folder, for example `& "$env:ProgramFiles\ODGO\Uninstall-Agent.ps1"`.
  It removes the scheduled task and the agent folder. Add `-RemoveData` to also delete the configuration, secret,
  state and logs.
* Fabric: delete the ODGO items, or the workspace.

## Security notes

* **Workspace role.** The agent identity is a Contributor of the workspace: it can write the landing folder, and it
  can also read the processed data and change the items of this workspace. Use a workspace dedicated to ODGO.
* **Agent folder.** The scheduled task runs the agent as SYSTEM, so only SYSTEM and Administrators can change the
  files of the `-InstallPath` folder. The installer refuses a folder created by another account or containing other
  files, so that nobody else can place code that would run as SYSTEM.
* **Client secret.** The secret is encrypted with DPAPI (machine scope) in a file that only SYSTEM, Administrators and
  the task identity can read, so any administrator of the server can decrypt it. The installer refuses a data folder
  created by another account, and the agent never passes the secret or a token to a command as text, so PowerShell
  module logging doesn't record them. Prefer a managed identity on Azure VMs and Azure Arc-enabled servers. Give the
  secret a limited lifetime and rotate it with `Install-Agent.ps1 -UpdateSecret`.
* **Network.** The agent only connects to Microsoft Entra ID (client secret) and OneLake, over HTTPS. A managed
  identity gets its token from a local endpoint: `169.254.169.254` on Azure VMs, `localhost:40342` on Azure Arc.
* **Collected data.** Gateway logs can contain query text, data source names and account names. See
  [Security and privacy](../README.md#security-and-privacy) in the README.

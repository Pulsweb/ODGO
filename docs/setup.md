# Setup

ODGO is installed in three steps:

1. [Create an identity for the agents](#1-create-an-identity-for-the-agents) in Microsoft Entra ID.
2. [Run the setup notebook](#2-run-the-setup-notebook) in a Fabric workspace.
3. [Install the agent](#3-install-the-agent-on-each-gateway-server) on each gateway server.

Upgrades run the same steps again: see [Upgrade](#upgrade).

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
   Name it, for example, `odgo-gateway-agent`, keep *Single tenant* and select **Register**.
2. Copy the **Application (client) ID** and the **Directory (tenant) ID**.
3. Open **Certificates & secrets** > **New client secret**, choose an expiry and copy the secret **Value** (not the
   *Secret ID*). It's shown only once; you type it on each gateway server in step 3.

No API permission is needed: the agent gets access through its workspace role
([Give the agents access to the workspace](#give-the-agents-access-to-the-workspace)). One app registration can
serve every gateway server. Plan the secret rotation before it expires ([operations.md](operations.md#agent)).

**Managed identity** (no secret): on an Azure VM or an [Azure Arc-enabled server](https://learn.microsoft.com/azure/azure-arc/servers/managed-identity-authentication),
use the server's system-assigned managed identity, which has the server's name. Each server has its own identity:
add each one to the workspace, or add a security group that contains them.

## 2. Run the setup notebook

1. Download [fabric/ODGO_Setup.ipynb](../fabric/ODGO_Setup.ipynb).
2. In the Fabric workspace, select **Import** > **Notebook** > **From this computer** and select the file.
3. Open the notebook. In the parameters cell, you can optionally set:
   * `agent_client_id`: the application (client) ID, used to complete the printed install command;
   * `agent_principal_id`: the Object ID of the agent identity, so that the notebook gives it the Contributor role on
     the workspace. Leave it empty to add the identity yourself after the run: see
     [Give the agents access to the workspace](#give-the-agents-access-to-the-workspace).
4. Select **Run all**. In a few minutes the notebook:
   * creates the lakehouse `lh_gateway_monitor` (with schemas);
   * imports the notebooks `nb_gwmon_lib`, `nb_gwmon_ingest` and `nb_gwmon_maintenance`, attached to the lakehouse;
   * runs `nb_gwmon_ingest` once, which creates the tables, the landing folder and `processing.json`;
   * creates the *Gateway Monitor* semantic model (Direct Lake) and report;
   * schedules `nb_gwmon_ingest` every 6 hours and `nb_gwmon_maintenance` once a day.
5. The last cell prints the PowerShell lines for step 3, with the IDs of your workspace, lakehouse and tenant.

The notebook downloads the ODGO version set in `source` (by default the `main` branch on GitHub). The other
parameters are described in [configuration.md](configuration.md#setup-notebook-parameters).

### Give the agents access to the workspace

The agent identity needs the **Contributor** role on the workspace to write to the lakehouse. Give it in one of two
ways:

* **In Fabric (simplest):** in the workspace, select **Manage access** > **Add people or groups**, type the name of the
  app registration (for example `odgo-gateway-agent`) or of the managed identity, select it, choose **Contributor**
  and select **Add**.
* **With the setup notebook:** before **Run all**, set `agent_principal_id` to the **Object ID** of the identity:
  * app registration: in the [Microsoft Entra admin center](https://entra.microsoft.com), open **Enterprise apps**,
    select the app and copy the **Object ID** of its **Overview** page, or run
    `az ad sp show --id <application-client-id> --query id --output tsv`. Two other IDs look similar but don't work:
    the *Application (client) ID*, and the *Object ID* shown under **App registrations**, which identifies the
    application rather than its service principal;
  * managed identity: in **Enterprise apps** > **All applications**, set the filter *Application type == Managed
    Identities*, select the server and copy its **Object ID**;
  * security group that contains the agent identities: the group's **Object ID**, with
    `agent_principal_type = "Group"`.

## 3. Install the agent on each gateway server

Open PowerShell 7 **as administrator** on the gateway server and paste the lines printed by the setup notebook:

```powershell
Invoke-WebRequest 'https://github.com/Pulsweb/ODGO/archive/refs/heads/main.zip' -OutFile odgo.zip
Remove-Item odgo -Recurse -Force -ErrorAction Ignore; Expand-Archive odgo.zip odgo
$installer = (Get-ChildItem odgo -Recurse -Filter Install-Agent.ps1 | Select-Object -First 1).FullName
& $installer -WorkspaceId <workspace-id> -LakehouseId <lakehouse-id> -TenantId <tenant-id> -ClientId <client-id>
```

You're prompted for the client secret value (input hidden). With a managed identity, replace `-TenantId … -ClientId …`
with `-ManagedIdentity`.

The installer:

* copies the agent to `%ProgramFiles%\ODGO`;
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
   of step 3, then `& $installer`). It replaces the agent files and keeps the configuration, secret, state and
   scheduled task.

## Uninstall

* Agent: `& "$env:ProgramFiles\ODGO\Uninstall-Agent.ps1"`. Add `-RemoveData` to also delete the
  configuration, secret, state and logs.
* Fabric: delete the ODGO items, or the workspace.

## Security notes

* **Workspace role.** The agent identity is a Contributor of the workspace: it can write the landing folder, and it
  can also read the processed data and change the items of this workspace. Use a workspace dedicated to ODGO.
* **Client secret.** The secret is encrypted with DPAPI (machine scope) in a file that only SYSTEM, Administrators and
  the task identity can read, so any administrator of the server can decrypt it. The installer refuses a data folder
  created by another account, and the agent never passes the secret or a token to a command as text, so PowerShell
  module logging doesn't record them. Prefer a managed identity on Azure VMs and Azure Arc-enabled servers. Give the
  secret a limited lifetime and rotate it with `Install-Agent.ps1 -UpdateSecret`.
* **Network.** The agent only connects to Microsoft Entra ID (client secret) and OneLake, over HTTPS. A managed
  identity gets its token from a local endpoint: `169.254.169.254` on Azure VMs, `localhost:40342` on Azure Arc.
* **Collected data.** Gateway logs can contain query text, data source names and account names. See
  [Security and privacy](../README.md#security-and-privacy) in the README.

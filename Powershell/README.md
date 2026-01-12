# PowerShell

My small, self-contained scripts and snippets. This code comes with no guarantees or support of any kind. Use at your own risk!

## Scripts

- `PowerShell/fwflowlog_toptalkers.ps1`: Identify Azure Firewall top talkers (sources/destinations) from Log Analytics (KQL).
- `PowerShell/subscription_nsg_inventory.ps1`: Export NSG inventory + rules to CSV.
- `PowerShell/subscription_quota_insights.ps1`: Export portal-style usage/quota insights to CSV.
- `PowerShell/resource_sku_insights.ps1`: Interactive Azure VM SKU insights (by series/region/restriction).

## Azure Firewall flow log top talkers (`PowerShell/fwflowlog_toptalkers.ps1`)

Queries Azure Firewall logs in Log Analytics and prints the top N sources and destinations (by total bytes), with optional CSV export.

### Prerequisites (Azure Firewall top talkers)

- PowerShell 7+ recommended (Windows PowerShell 5.1 may work)
- Az modules installed (at minimum `Az.Accounts` and `Az.OperationalInsights`). Install with: `Install-Module Az -Scope CurrentUser`
- Azure Firewall diagnostics flowing to a Log Analytics workspace (e.g., `AZFWFlowLog` category)

### Run (Azure Firewall top talkers)

From the `PowerShell/` folder:

```powershell
./fwflowlog_toptalkers.ps1 \
  -SubscriptionId "00000000-0000-0000-0000-000000000000" \
  -WorkspaceName "my-law" \
  -TimeRange "1h" \
  -TopN 50
```

Optional flags:

- `-ResourceGroup <rg>` (if workspace name is not unique)
- `-Direction Inbound|Outbound|Any` (default: `Any`)
- `-Protocol TCP|UDP|ICMP|Any` (default: `Any`)
- `-SourceIpPrefix <cidr>` and/or `-DestIpPrefix <cidr>`
- `-LogCategories AZFWFlowLog,AzureFirewallNetworkRule,AzureFirewallApplicationRule`
- `-SaveCsv` (exports results to CSV files in the current folder)

### Output (Azure Firewall top talkers)

- Prints `Top Sources` and `Top Destinations` tables to the console
- With `-SaveCsv`, writes:
  - `TopSources_AzureFirewall_<TimeRange>_<yyyyMMddHHmmss>.csv`
  - `TopDestinations_AzureFirewall_<TimeRange>_<yyyyMMddHHmmss>.csv`

## Subscription NSG inventory (`PowerShell/subscription_nsg_inventory.ps1`)

Exports all Network Security Groups (NSGs) in a subscription and their rules to a timestamped CSV.

### Prerequisites (Subscription NSG inventory)

- PowerShell 7+ recommended (Windows PowerShell 5.1 may work)
- Az modules installed (at minimum `Az.Accounts` and `Az.Network`). Install with: `Install-Module Az -Scope CurrentUser`

### Run (Subscription NSG inventory)

From the `PowerShell/` folder:

```powershell
./subscription_nsg_inventory.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

### Output (Subscription NSG inventory)

- Writes a CSV to: `PowerShell/output/nsg-export-<yyyyMMdd-HHmmss>.csv`

## Subscription quota insights (`PowerShell/subscription_quota_insights.ps1`)

Exports a portal-style "Usage + quotas" report to CSV, scoped to providers/regions where resources are provisioned.

### Prerequisites (Subscription quota insights)

- PowerShell 7+ recommended (Windows PowerShell 5.1 may work)
- Az modules installed:
  - Required: `Az.Accounts`
  - For quota/usage retrieval (as available): `Az.Compute`, `Az.Network`, `Az.Storage`
  - Install: `Install-Module Az -Scope CurrentUser`

### Run (Subscription quota insights)

From the `PowerShell/` folder:

```powershell
./subscription_quota_insights.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

### Output (Subscription quota insights)

- Writes a CSV to: `PowerShell/output/quota-export-<yyyyMMdd-HHmmss>.csv`
- Only exports rows where `CurrentValue > 0`
- Includes `Trigger_Quota_Request` which is `true` when `(CurrentValue / Limit) > 0.1`
- Columns include: `ProviderNamespace`, `Location`, `QuotaName`, `QuotaId`, `CurrentValue`, `Limit`, `Unit`, `PercentUsed`, `ProvisionedCount`, `Trigger_Quota_Request`

## Resource SKU insights (`PowerShell/resource_sku_insights.ps1`)

Interactive tool to query Azure VM SKUs in a region and show key capabilities (vCPUs, memory, max NICs, accelerated networking, architecture) for a selected VM family/series.

### Prerequisites (Resource SKU insights)

- PowerShell 7+ recommended (Windows PowerShell 5.1 may work)
- Azure CLI installed (`az`)
- Logged in to Azure CLI (`az login`)
- Optional: set the desired subscription (`az account set -s <subscriptionId>`)

### Run (Resource SKU insights)

From the `PowerShell/` folder:

```powershell
./resource_sku_insights.ps1
```

### Output (Resource SKU insights)

- Writes a CSV to: `PowerShell/output/sku-export-<yyyyMMdd-HHmmss>.csv`
- Columns include: `Location`, `VmType`, `FilterType`, `Name`, `Restrictions`, `vCPUs`, `MemoryGB`, `MaxNICs`, `AccelNet`, `Architecture`

## Generated output

- `PowerShell/output/`: Folder where the scripts write timestamped CSV exports.

# PowerShell

My small, self-contained scripts and snippets. This code comes with no guarantees or support of any kind. Use at your own risk!

## Scripts

- `PowerShell/fwflowlog_toptalkers.ps1`: Identify Azure Firewall top talkers (sources/destinations) from Log Analytics (KQL).
- `PowerShell/subscription_storage_capacityusage.ps1`: Report Storage Account Used Capacity and Blob Capacity (Azure Monitor metrics).
- `PowerShell/subscription_nsg_inventory.ps1`: Export NSG inventory + rules to CSV.
- `PowerShell/subscription_quota_insights.ps1`: Export portal-style usage/quota insights to CSV.
- `PowerShell/resource_sku_insights.ps1`: Interactive Azure VM SKU insights (by series/region/restriction).
- `PowerShell/mgmtgrp_policyexemptions.ps1`: Bulk-create Azure Policy exemptions for non-compliant resources under a management group (supports multiple policy assignments; skips if an exemption already exists).

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

## Subscription storage capacity usage (`PowerShell/subscription_storage_capacityusage.ps1`)

Lists storage accounts in a subscription and queries Azure Monitor Metrics to report:

- `AccountUsedCapacityGB`: Account-level used capacity (all services)
- `BlobUsedCapacityGB`: Blob-service-only capacity
- `AccountMaxCapacityGB`: Planning max capacity (only populated for Standard tier)
- `AccountAvailableCapacityGB`: Max minus used (only when max is known)

Notes:

- Capacity metrics are sampled hourly (`PT1H`). The script queries a lookback window (`$LookbackHours`) and returns the most recent datapoint.
- Values are output in **decimal GB** (1 GB = 1,000,000,000 bytes).

### Prerequisites (Storage capacity usage)

- Azure CLI installed (`az`)
- Logged in to Azure CLI (`az login`)
- Reader (or higher) on the subscription
- Optional: set the desired subscription (`az account set -s <subscriptionId>`)

### Run (Storage capacity usage)

From the `PowerShell/` folder:

```powershell
./subscription_storage_capacityusage.ps1
```

### Output (Storage capacity usage)

- Writes a CSV to: `PowerShell/output/storage-capacity-export-<yyyyMMdd-HHmmss>.csv`
- Columns include: `StorageAccount`, `ResourceGroup`, `Location`, `AccountUsedCapacityGB`, `BlobUsedCapacityGB`, `AccountMaxCapacityGB`, `AccountAvailableCapacityGB`

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

## Management group policy exemptions (`PowerShell/output/mgmtgrp_policyexemptions.ps1`)

Bulk-creates Azure Policy exemptions for resources currently `NonCompliant` under a management group for **one or more** policy assignments.

The script will **skip** creating a per-resource exemption if an exemption already exists for the same assignment at any of these scopes:

- Management group
- Subscription
- Resource group
- Resource

### Prerequisites (MG policy exemptions)

- PowerShell 7+ recommended
- Az modules installed:
  - `Az.Accounts`
  - `Az.PolicyInsights`
  - `Az.Resources`

### Run (MG policy exemptions)

This script is configured via variables at the top of the file:

- Set `$ManagementGroupName`
- Populate `$PolicyAssignmentIds = @("<assignmentId1>", "<assignmentId2>")`
- Optional: set `$WhatIf = $true` to preview without creating exemptions

From the `PowerShell/` folder:

```powershell
./output/mgmtgrp_policyexemptions.ps1
```

## Generated output

- `PowerShell/output/`: Folder where the scripts write timestamped CSV exports.

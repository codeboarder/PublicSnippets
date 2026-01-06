# PublicSnippets

My small, self-contained scripts and snippets. This code comes with no guarantees or support of any kind. Use at your own risk!

## PowerShell

### Scripts

- `Powershell/subscription_nsg_inventory.ps1`: Export NSG inventory + rules to CSV.
- `Powershell/subscription_quota_insights.ps1`: Export portal-style usage/quota insights to CSV.

### Subscription NSG inventory (`Powershell/subscription_nsg_inventory.ps1`)

Exports all Network Security Groups (NSGs) in a subscription and their rules to a timestamped CSV.

#### Prerequisites (NSG)

- PowerShell 7+ recommended (Windows PowerShell 5.1 may work)
- Az modules installed (at minimum `Az.Accounts` and `Az.Network`). Install with: `Install-Module Az -Scope CurrentUser`

#### Run (NSG)

From the `Powershell/` folder:

```powershell
./subscription_nsg_inventory.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

#### Output (NSG)

- Writes a CSV to: `Powershell/output/nsg-export-<yyyyMMdd-HHmmss>.csv`

### Subscription quota insights (`Powershell/subscription_quota_insights.ps1`)

Exports a portal-style "Usage + quotas" report to CSV, scoped to providers/regions where resources are provisioned.

#### Prerequisites (Quota)

- PowerShell 7+ recommended (Windows PowerShell 5.1 may work)
- Az modules installed:
  - Required: `Az.Accounts`
  - For quota/usage retrieval (as available): `Az.Compute`, `Az.Network`, `Az.Storage`
  - Install: `Install-Module Az -Scope CurrentUser`

#### Run (Quota)

From the `Powershell/` folder:

```powershell
./subscription_quota_insights.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

#### Output (Quota)

- Writes a CSV to: `Powershell/output/quota-export-<yyyyMMdd-HHmmss>.csv`
- Only exports rows where `CurrentValue > 0`
- Includes `Trigger_Quota_Request` which is `true` when `(CurrentValue / Limit) > 0.1`
- Columns include: `ProviderNamespace`, `Location`, `QuotaName`, `QuotaId`, `CurrentValue`, `Limit`, `Unit`, `PercentUsed`, `ProvisionedCount`, `Trigger_Quota_Request`

## Generated output

- `Powershell/output/`: Folder where the scripts write timestamped CSV exports.


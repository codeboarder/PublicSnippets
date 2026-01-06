# PublicSnippets

My small, self-contained scripts and snippets. This code comes with no guarantees or support of any kind. Use at your own risk!

## PowerShell

### NSG export (`Powershell/nsgs.ps1`)

Exports all Network Security Groups (NSGs) in a subscription and their rules to a timestamped CSV.

**Prerequisites**

- PowerShell 7+ recommended (Windows PowerShell 5.1 may work)
- Az modules installed (at minimum `Az.Accounts` and `Az.Network`)
	- Install: `Install-Module Az -Scope CurrentUser`

**Run**

From the `Powershell/` folder:

```powershell
./nsgs.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"
```

**Output**

- Writes a CSV to: `Powershell/output/nsg-export-<yyyyMMdd-HHmmss>.csv`
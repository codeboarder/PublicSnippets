<#!
.SYNOPSIS
Exports Azure subscription usage and quota information (portal-style) to a timestamped CSV.

.DESCRIPTION
Connects to Azure (if needed), sets the specified subscription context, enumerates provisioned resources,
and exports a "Usage + quotas" style report to a CSV file. The report is limited to providers/regions where
resources are currently provisioned, and includes usage/limit values when the provider exposes them.

Only quota rows with a CurrentValue greater than 0 are exported. The output includes a
Trigger_Quota_Request flag that is true when (CurrentValue / Limit) > threshold

.PARAMETER SubscriptionId
The Azure subscription ID (GUID) to query.

.EXAMPLE
./subscription_quota_insights.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.NOTES
Requires Az PowerShell modules (at minimum: Az.Accounts). Quota/usage retrieval depends on provider modules
being installed (for example: Az.Compute, Az.Network, Az.Storage).

Currently supported providers: Microsoft.Compute, Microsoft.Network, Microsoft.Storage (when the corresponding
Az.* modules are installed and the usage cmdlets are available).
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = 'Azure subscription ID (GUID)')]
    [ValidateNotNullOrEmpty()]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId
)

# Stop on errors
$ErrorActionPreference = 'Stop'

# Ensure Az modules are available
if (-not (Get-Module -ListAvailable -Name Az.Accounts)) {
    Write-Error "Az module not found. Install with: Install-Module Az -Scope CurrentUser"
    exit 1
}

try {
    # Output files (written next to this script)
    $OutputDir = $PSScriptRoot
    if (-not $OutputDir) { $OutputDir = (Get-Location).Path }
    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $CsvPath = Join-Path $OutputDir "\\output\\quota-export-$Timestamp.csv"

    # Sign in if there is no current context
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Write-Host "Signing in to Azure..." -ForegroundColor Cyan
        Connect-AzAccount | Out-Null
    }

    # Set subscription context
    Write-Host "Setting context to subscription: $SubscriptionId" -ForegroundColor Cyan
    Set-AzContext -Subscription $SubscriptionId | Out-Null

    # Fetch provisioned resources (used to scope provider/region like the Azure portal "Usage + quotas" page)
    Write-Host "Discovering provisioned Azure resources..." -ForegroundColor Cyan
    $resources = Get-AzResource

    if (-not $resources -or $resources.Count -eq 0) {
        Write-Warning "No resources found in subscription $SubscriptionId."
        return
    }

    # Ensure output folder exists
    $csvDir = Split-Path -Parent $CsvPath
    if (-not (Test-Path -Path $csvDir)) {
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    }

    function Get-ProviderNamespace {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ResourceType
        )
        # ResourceType looks like: Microsoft.Compute/virtualMachines
        ($ResourceType -split '/', 2)[0]
    }

    function Get-QuotaUsageRows {
        param(
            [Parameter(Mandatory = $true)]
            [string]$ProviderNamespace,

            [Parameter(Mandatory = $true)]
            [string]$Location,

            [Parameter(Mandatory = $true)]
            [int]$ResourceCount
        )

        $cmd = $null
        switch ($ProviderNamespace) {
            'Microsoft.Compute'  { $cmd = 'Get-AzVMUsage' }
            'Microsoft.Network'  { $cmd = 'Get-AzNetworkUsage' }
            'Microsoft.Storage'  { $cmd = 'Get-AzStorageUsage' }
            default              { return @() }
        }

        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            Write-Warning "Skipping $ProviderNamespace in $Location (missing cmdlet: $cmd)."
            return @()
        }

        $items = @()
        try {
            $items = & $cmd -Location $Location
        } catch {
            Write-Warning "Failed to retrieve usage for $ProviderNamespace in $Location. $($_.Exception.Message)"
            return @()
        }

        $pctThreshold = 0.1
        foreach ($item in @($items)) {
            $quotaId = ''
            $quotaName = ''
            if ($item.Name) {
                $quotaId = $item.Name.Value
                $quotaName = if ($item.Name.LocalizedValue) { $item.Name.LocalizedValue } else { $item.Name.Value }
            }

            $current = $item.CurrentValue
            $limit = $item.Limit
            $unit = $item.Unit
            $pct = $null
            if ($null -ne $limit -and [double]$limit -gt 0 -and $null -ne $current) {
                $pct = [math]::Round(([double]$current / [double]$limit) * 100, 2)
            }

         [PSCustomObject]@{
                Trigger_Quota_Request = ($pct -gt $pctThreshold)
                PercentUsed       = $pct
                ProviderNamespace = $ProviderNamespace
                Location          = $Location
                QuotaName         = $quotaName
                QuotaId           = $quotaId
                CurrentValue      = $current
                Limit             = $limit
                Unit              = $unit
                ProvisionedCount  = $ResourceCount

            }
        }
    }

    # Build provider/region inventory from provisioned resources
    $providerLocationCounts = @{}
    foreach ($res in @($resources)) {
        $provider = if ($res.ResourceType) { Get-ProviderNamespace -ResourceType $res.ResourceType } else { '' }
        $location = if ($res.Location) { $res.Location.ToString().Trim() } else { '' }

        if ([string]::IsNullOrWhiteSpace($provider) -or [string]::IsNullOrWhiteSpace($location)) { continue }

        $key = ($provider + '|' + $location)
        if ($providerLocationCounts.ContainsKey($key)) {
            $providerLocationCounts[$key]++
        } else {
            $providerLocationCounts[$key] = 1
        }
    }

    if ($providerLocationCounts.Count -eq 0) {
        Write-Warning "No provisioned resources with a region were found in subscription $SubscriptionId."
        return
    }

    # Fetch quota/usage only for providers/regions where resources exist
    Write-Host "Retrieving usage + quota information (where available)..." -ForegroundColor Cyan
    $quotaRows = foreach ($key in ($providerLocationCounts.Keys | Sort-Object)) {
        $parts = $key -split '\|', 2
        $provider = $parts[0]
        $location = $parts[1]
        $count = [int]$providerLocationCounts[$key]

        Get-QuotaUsageRows -ProviderNamespace $provider -Location $location -ResourceCount $count
    }

    # Match the portal experience: only show entries with current usage > 0
    $quotaRows = @($quotaRows | Where-Object {
        $cv = $_.CurrentValue
        if ($null -eq $cv -or $cv -eq '') { return $false }
        ([double]$cv -gt 0)
    })

    if (-not $quotaRows -or $quotaRows.Count -eq 0) {
        Write-Warning "No usage/quota results with CurrentValue > 0 were returned. Ensure provider modules are installed (e.g., Az.Compute/Az.Network/Az.Storage) and try again."
        return
    }

    $quotaRows |
        Sort-Object ProviderNamespace, Location, QuotaName |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    Write-Host "`nWrote CSV output:" -ForegroundColor Cyan
    Write-Host "- $CsvPath" -ForegroundColor Cyan

} catch {
    Write-Error "Failed to export usage/quota insights. $($_.Exception.Message)"
    throw
}

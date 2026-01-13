
<#
Prereqs:
- Install Azure CLI and sign in: az login
- You must have Reader or higher on the subscription(s)

What it does:
1) Gets an AAD bearer token (for ARM + Monitor).
2) Lists all storage accounts in the current subscription.
3) For each storage account, queries Azure Monitor Metrics (UsedCapacity at storage account scope) and (BlobCapacity at blobServices scope).
4) Emits a formatted table.

If you want to target a specific subscription:
- Set $SubscriptionId explicitly or run `az account set -s <your-subscription-id>`
#>

# ========== Config ==========
# If you want to pin a subscription, uncomment and set:
# $SubscriptionId = "<SUBSCRIPTION_ID>"
# Else, we’ll use the current az account context.
$LookbackHours = 6           # UsedCapacity is sampled hourly (PT1H); we take the most recent datapoint as "current"
$Interval      = "PT1H"      # UsedCapacity supports PT1H time grain
$Aggregation   = "Average"   # UsedCapacity is a gauge-like metric; Average is typically used
$ApiVersionARM = "2023-01-01"
$ApiVersionMon = "2018-01-01"

function New-AzMonitorTimespan {
    param(
        [Parameter(Mandatory=$true)][int]$LookbackHours
    )
    $endUtc   = (Get-Date).ToUniversalTime()
    $startUtc = $endUtc.AddHours(-1 * [Math]::Abs($LookbackHours))
    $startStr = $startUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    $endStr   = $endUtc.ToString("yyyy-MM-ddTHH:mm:ssZ")
    return "$startStr/$endStr"
}

# ========== Helpers ==========
function Get-BearerToken {
    # Uses Azure CLI to get an access token suitable for ARM and Monitor
    $tok = az account get-access-token --resource "https://management.azure.com/" --output json | ConvertFrom-Json
    if (-not $tok.accessToken) {
        throw "Failed to obtain access token. Run 'az login' and ensure you have access."
    }
    return $tok.accessToken
}

function Get-CurrentSubscriptionId {
    if ($Script:SubscriptionId) { return $Script:SubscriptionId }
    $ctx = az account show --output json | ConvertFrom-Json
    if (-not $ctx.id) {
        throw "No subscription context. Run 'az account set -s <subscription-id>' or 'az login'."
    }
    return $ctx.id
}

function Invoke-ArmGet {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Bearer
    )
    $headers = @{ 
        "Authorization" = "Bearer $Bearer"
        "Content-Type"  = "application/json"
    }
    return Invoke-RestMethod -Method GET -Uri $Url -Headers $headers
}

# Query Azure Monitor metrics for Storage Account "UsedCapacity" (all services)
function Get-StorageAccountUsedCapacityBytes {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroup,
        [Parameter(Mandatory=$true)][string]$StorageAccountName,
        [Parameter(Mandatory=$true)][string]$Bearer,
        [Parameter(Mandatory=$true)][string]$TimeSpan,
        [string]$Interval     = "PT1H",
        [string]$Aggregation  = "Average"
    )

    # IMPORTANT: UsedCapacity is defined at the storage account scope (Microsoft.Storage/storageAccounts)
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccountName"

    # Build Metrics REST URL
    $base = "https://management.azure.com$resourceId/providers/microsoft.insights/metrics"
    $escapedTimespan = [uri]::EscapeDataString($TimeSpan)
    $query = @(
        "api-version=$ApiVersionMon",
        "metricnames=UsedCapacity",
        "timespan=$escapedTimespan",
        "interval=$Interval",
        "aggregation=$Aggregation",
        "metricnamespace=Microsoft.Storage/storageAccounts"
    ) -join "&"
    $url = "$base`?$query"

    $headers = @{ 
        "Authorization" = "Bearer $Bearer"
        "Content-Type"  = "application/json"
    }

    try {
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers
    } catch {
        Write-Verbose "Metrics query failed for ${StorageAccountName}: $_"
        return $null
    }

    # Parse the metric payload safely
    # Structure: value[0].timeseries[0].data[*].<aggregation>
    if ($resp.value -and $resp.value.Count -gt 0) {
        $ts = $resp.value[0].timeseries
        if ($ts -and $ts.Count -gt 0) {
            $dataPoints = $ts[0].data
            if ($dataPoints -and $dataPoints.Count -gt 0) {
                # Take the most recent non-null datapoint
                $ordered = $dataPoints | Sort-Object -Property timeStamp -Descending
                foreach ($dp in $ordered) {
                    $val = $null
                    switch ($Aggregation.ToLower()) {
                        "average" { $val = $dp.average }
                        "total"   { $val = $dp.total }
                        default   { $val = $dp.average }
                    }
                    if ($null -ne $val) { return [double]$val }
                }
            }
        }
    }
    return $null
}

# Query Azure Monitor metrics for Blob service "BlobCapacity" (blob-only)
function Get-BlobCapacityBytes {
    param(
        [Parameter(Mandatory=$true)][string]$SubscriptionId,
        [Parameter(Mandatory=$true)][string]$ResourceGroup,
        [Parameter(Mandatory=$true)][string]$StorageAccountName,
        [Parameter(Mandatory=$true)][string]$Bearer,
        [Parameter(Mandatory=$true)][string]$TimeSpan,
        [string]$Interval     = "PT1H",
        [string]$Aggregation  = "Average"
    )

    # IMPORTANT: BlobCapacity is defined at the blobServices/default scope (Microsoft.Storage/storageAccounts/blobServices)
    $resourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/blobServices/default"

    # Build Metrics REST URL
    $base = "https://management.azure.com$resourceId/providers/microsoft.insights/metrics"
    $escapedTimespan = [uri]::EscapeDataString($TimeSpan)
    $query = @(
        "api-version=$ApiVersionMon",
        "metricnames=BlobCapacity",
        "timespan=$escapedTimespan",
        "interval=$Interval",
        "aggregation=$Aggregation",
        "metricnamespace=Microsoft.Storage/storageAccounts/blobServices"
    ) -join "&"
    $url = "$base`?$query"

    $headers = @{
        "Authorization" = "Bearer $Bearer"
        "Content-Type"  = "application/json"
    }

    try {
        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers
    } catch {
        Write-Verbose "Metrics query failed for ${StorageAccountName} (BlobCapacity): $_"
        return $null
    }

    if ($resp.value -and $resp.value.Count -gt 0) {
        $ts = $resp.value[0].timeseries
        if ($ts -and $ts.Count -gt 0) {
            $dataPoints = $ts[0].data
            if ($dataPoints -and $dataPoints.Count -gt 0) {
                $ordered = $dataPoints | Sort-Object -Property timeStamp -Descending
                foreach ($dp in $ordered) {
                    $val = $null
                    switch ($Aggregation.ToLower()) {
                        "average" { $val = $dp.average }
                        "total"   { $val = $dp.total }
                        default   { $val = $dp.average }
                    }
                    if ($null -ne $val) { return [double]$val }
                }
            }
        }
    }
    return $null
}

# ========== Main ==========
try {
    $Bearer = Get-BearerToken
    $SubId  = Get-CurrentSubscriptionId
    $TimeSpan = New-AzMonitorTimespan -LookbackHours $LookbackHours

    # 1) List Storage Accounts (ARM)
    $listUrl = "https://management.azure.com/subscriptions/$SubId/providers/Microsoft.Storage/storageAccounts?api-version=$ApiVersionARM"
    $saList  = Invoke-ArmGet -Url $listUrl -Bearer $Bearer

    if (-not $saList.value -or $saList.value.Count -eq 0) {
        Write-Host "No storage accounts found in subscription $SubId."
        return
    }

    $results = @()
    foreach ($sa in $saList.value) {
        $id   = $sa.id
        $name = $sa.name
        $loc  = $sa.location

        # Extract resource group from the resource ID
        # ID format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Storage/storageAccounts/{name}
        $resourceGroup = ($id -split "/")[4]

        # 2) Query UsedCapacity for the storage account and BlobCapacity for the blob service (hourly metrics)
        $usedBytes = Get-StorageAccountUsedCapacityBytes -SubscriptionId $SubId -ResourceGroup $resourceGroup -StorageAccountName $name -Bearer $Bearer -TimeSpan $TimeSpan -Interval $Interval -Aggregation $Aggregation
        $blobBytes = Get-BlobCapacityBytes -SubscriptionId $SubId -ResourceGroup $resourceGroup -StorageAccountName $name -Bearer $Bearer -TimeSpan $TimeSpan -Interval $Interval -Aggregation $Aggregation

        # Decimal GB: 1 GB = 1,000,000,000 bytes
        $usedGB = $null
        $blobGB = $null
        if ($null -ne $usedBytes) {
            $usedGB = [Math]::Round(($usedBytes / 1000000000), 2)
        }
        if ($null -ne $blobBytes) {
            $blobGB = [Math]::Round(($blobBytes / 1000000000), 2)
        }

        $results += [pscustomobject]@{
            StorageAccount = $name
            ResourceGroup  = $resourceGroup
            Location       = $loc
            UsedCapacityGB = $usedGB
            BlobCapacityGB = $blobGB
        }
    }

    # 3) Output
    $results | Sort-Object StorageAccount | Format-Table -AutoSize

} catch {
    Write-Error $_
}


<#
.SYNOPSIS
  Identify Top N talkers (sources/destinations) using Azure Firewall flow logs (AZFWFlowLog) in Log Analytics.

.PARAMETER SubscriptionId
  Target subscription GUID.

.PARAMETER WorkspaceName
  Log Analytics workspace name.

.PARAMETER ResourceGroup
  (Optional) Resource group of the Log Analytics workspace for disambiguation.

.PARAMETER TimeRange
  Query window: e.g. 30m, 1h, 24h, 7d. Default: 1h.

.PARAMETER TopN
  Number of top entries to return. Default: 50.

.PARAMETER LogCategories
  Which Azure Firewall categories to include. Default: AZFWFlowLog.
  (You may also include AzureFirewallNetworkRule, AzureFirewallApplicationRule.)

.PARAMETER Direction
  Inbound | Outbound | Any. Default: Any.

.PARAMETER Protocol
  TCP | UDP | ICMP | Any. Default: Any.

.PARAMETER SourceIpPrefix
  (Optional) CIDR or IP prefix filter for sources (e.g., 10.10.0.0/16).

.PARAMETER DestIpPrefix
  (Optional) CIDR or IP prefix filter for destinations.

.PARAMETER SaveCsv
  Switch to export results as CSV files in the current folder.

.NOTES
  Requires modules: Az.Accounts, Az.OperationalInsights.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)]
  [string]$SubscriptionId,

  [Parameter(Mandatory=$true)]
  [string]$WorkspaceName,

  [Parameter(Mandatory=$false)]
  [string]$ResourceGroup,

  [Parameter(Mandatory=$false)]
  [ValidatePattern('^\d+[mhd]$')]
  [string]$TimeRange = '1h',

  [Parameter(Mandatory=$false)]
  [int]$TopN = 50,

  [Parameter(Mandatory=$false)]
  [string[]]$LogCategories = @('AZFWFlowLog'),

  [Parameter(Mandatory=$false)]
  [ValidateSet('Inbound','Outbound','Any')]
  [string]$Direction = 'Any',

  [Parameter(Mandatory=$false)]
  [ValidateSet('TCP','UDP','ICMP','Any')]
  [string]$Protocol = 'Any',

  [Parameter(Mandatory=$false)]
  [string]$SourceIpPrefix,

  [Parameter(Mandatory=$false)]
  [string]$DestIpPrefix,

  [Parameter(Mandatory=$false)]
  [switch]$SaveCsv
)

function Ensure-Module {
  param([string]$Name)
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    Write-Host "Installing module $Name ..." -ForegroundColor Yellow
    Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
  }
  Import-Module $Name -ErrorAction Stop
}

# Auth & subscription
Ensure-Module -Name Az.Accounts
Ensure-Module -Name Az.OperationalInsights

Write-Host "Connecting to Azure..." -ForegroundColor Cyan
Connect-AzAccount -ErrorAction Stop | Out-Null
Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop

# Resolve workspace
$ws = $null
if ($ResourceGroup) {
  $ws = Get-AzOperationalInsightsWorkspace -ResourceGroupName $ResourceGroup -Name $WorkspaceName -ErrorAction Stop
} else {
  $ws = Get-AzOperationalInsightsWorkspace -Name $WorkspaceName -ErrorAction Stop
  if (-not $ws) {
    throw "Workspace '$WorkspaceName' not found. Consider specifying -ResourceGroup."
  }
}

$workspaceId = $ws.CustomerId

# Build KQL dynamically
# Map helper filters to KQL
$directionFilter = switch ($Direction) {
  'Inbound'  { " | where iff(isnull(Direction), tostring(Direction_s), tostring(Direction_s)) =~ 'Inbound'" }
  'Outbound' { " | where iff(isnull(Direction), tostring(Direction_s), tostring(Direction_s)) =~ 'Outbound'" }
  default    { "" }
}

$protocolFilter = if ($Protocol -ne 'Any') {
  " | where tostring(coalesce(Protocol_s, L4Protocol_s, Protocol)) =~ '$Protocol'"
} else { "" }

$srcFilter = if ($SourceIpPrefix) {
  " | where ipv4_is_in_range(tostring(coalesce(SrcIp_s, SourceIp)), '$SourceIpPrefix')"
} else { "" }

$dstFilter = if ($DestIpPrefix) {
  " | where ipv4_is_in_range(tostring(coalesce(DstIp_s, DestinationIp)), '$DestIpPrefix')"
} else { "" }

# Categories clause (supports AZFWFlowLog plus rule-level categories)
$categoryList = ($LogCategories | ForEach-Object { "'$_'" }) -join ", "
$categoryFilter = " | where Category in ($categoryList)"

# Construct base query
$kqlTopSources = @"
let startTime = ago($TimeRange);
AzureDiagnostics
| where TimeGenerated >= startTime
$categoryFilter
| extend Src = tostring(coalesce(SrcIp_s, SourceIp))
| extend Dst = tostring(coalesce(DstIp_s, DestinationIp))
| extend L4Proto = tostring(coalesce(Protocol_s, L4Protocol_s, Protocol))
| extend SentBytes_d = todouble(coalesce(SentBytes, SentBytes_s, 0))
| extend ReceivedBytes_d = todouble(coalesce(ReceivedBytes, ReceivedBytes_s, 0))
| extend Bytes_d = iif(isnull(SentBytes_d) and isnull(ReceivedBytes_d), todouble(coalesce(Bytes_s, 0)), SentBytes_d + ReceivedBytes_d)
| extend Packets_d = todouble(coalesce(Packets_s, 0))
$directionFilter
$protocolFilter
$srcFilter
$dstFilter
| summarize TotalBytes=sum(Bytes_d), TotalPackets=sum(Packets_d), Flows=count() by Src
| order by TotalBytes desc
| take $TopN
"@

$kqlTopDests = $kqlTopSources.Replace("by Src","by Dst").Replace("order by TotalBytes desc","order by TotalBytes desc") # reuse

Write-Host "Running KQL for Top Sources over $TimeRange..." -ForegroundColor Cyan
$resultSrc = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $kqlTopSources -ErrorAction Stop
Write-Host "Running KQL for Top Destinations over $TimeRange..." -ForegroundColor Cyan
$resultDst = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceId -Query $kqlTopDests -ErrorAction Stop

function Convert-Results {
  param($result, [string]$key)
  if (-not $result.Tables -or $result.Tables.Count -eq 0) { return @() }
  $t = $result.Tables[0]
  $rows = @()
  foreach ($r in $t.Rows) {
    $obj = [PSCustomObject]@{
      Rank         = 0
      ($key)       = $r[0]
      TotalBytes   = [double]$r[1]
      TotalPackets = [double]$r[2]
      Flows        = [int]$r[3]
    }
    $rows += $obj
  }
  # Rank them
  $ranked = $rows | Sort-Object -Property TotalBytes -Descending
  $i = 1
  foreach ($row in $ranked) { $row.Rank = $i; $i++ }
  return $ranked
}

$srcRows = Convert-Results -result $resultSrc -key 'SourceIp'
$dstRows = Convert-Results -result $resultDst -key 'DestinationIp'

Write-Host "`nTop Sources:" -ForegroundColor Green
$srcRows | Format-Table -AutoSize

Write-Host "`nTop Destinations:" -ForegroundColor Green
$dstRows | Format-Table -AutoSize

if ($SaveCsv) {
  $ts = Get-Date -Format 'yyyyMMddHHmmss'
  $file1 = "TopSources_AzureFirewall_${TimeRange}_${ts}.csv"
  $file2 = "TopDestinations_AzureFirewall_${TimeRange}_${ts}.csv"
  $srcRows | Export-Csv -Path $file1 -NoTypeInformation -Encoding UTF8
  $dstRows | Export-Csv -Path $file2 -NoTypeInformation -Encoding UTF8
  Write-Host "Saved CSV: $file1" -ForegroundColor Yellow
  Write-Host "Saved CSV: $file2" -ForegroundColor Yellow
}

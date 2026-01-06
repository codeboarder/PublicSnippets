<#!
.SYNOPSIS
Exports Azure Network Security Groups (NSGs) and their rules to a timestamped CSV.

.DESCRIPTION
Connects to Azure (if needed), sets the specified subscription context, enumerates all Network Security Groups,
and exports a combined NSG + rule report (one row per rule) to a CSV file. The export includes basic NSG
metadata, associations (subnets/NICs), rule properties, and a simple redundancy marker.

.PARAMETER SubscriptionId
The Azure subscription ID (GUID) to query.

.EXAMPLE
./nsgs.ps1 -SubscriptionId "00000000-0000-0000-0000-000000000000"

.NOTES
Requires the Az PowerShell modules (at minimum: Az.Accounts and Az.Network) and permissions to read NSGs.
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
    $CsvPath = Join-Path $OutputDir "\\output\\nsg-export-$Timestamp.csv"

    # Sign in if there is no current context
    $ctx = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $ctx) {
        Write-Host "Signing in to Azure..." -ForegroundColor Cyan
        Connect-AzAccount | Out-Null
    }

    # Set subscription context
    Write-Host "Setting context to subscription: $SubscriptionId" -ForegroundColor Cyan
    Set-AzContext -Subscription $SubscriptionId | Out-Null

    # Fetch NSGs
    Write-Host "Discovering Network Security Groups..." -ForegroundColor Cyan
    $nsgs = Get-AzNetworkSecurityGroup

    if (-not $nsgs -or $nsgs.Count -eq 0) 
    {
        Write-Warning "No NSGs found in subscription $SubscriptionId."
        return
    }

    # Build console table objects
    $rows = foreach ($nsg in $nsgs) 
    {
        # Associations can be $null; normalize to IDs
        $subnetIds = @($nsg.Subnets | ForEach-Object { $_.Id })
        $nicIds    = @($nsg.NetworkInterfaces | ForEach-Object { $_.Id })

        # Shorten association lists for readability (first 2 items)
        $subnetsShort = if ($subnetIds.Count -gt 0) {
            $suffix = ($subnetIds.Count -gt 2) ? ' …' : ''
            (($subnetIds | Select-Object -First 2) -join '; ') + $suffix
        } else { '' }

        $nicsShort = if ($nicIds.Count -gt 0) {
            $suffix = ($nicIds.Count -gt 2) ? ' …' : ''
            (($nicIds | Select-Object -First 2) -join '; ') + $suffix
        } else { '' }

        # Rule counts
        $customRuleCount  = ($nsg.SecurityRules         | Measure-Object).Count
        $defaultRuleCount = ($nsg.DefaultSecurityRules  | Measure-Object).Count
        $totalRuleCount   = $customRuleCount + $defaultRuleCount

        # Emit a PSObject with the columns we want
        [PSCustomObject]@{
            NSGName           = $nsg.Name
            ResourceGroup     = $nsg.ResourceGroupName
            Location          = $nsg.Location
            Rules_Total       = $totalRuleCount
            Rules_Custom      = $customRuleCount
            Rules_Default     = $defaultRuleCount
            AssociatedSubnets = $subnetsShort
            AssociatedNICs    = $nicsShort
        }
    }

    function Normalize-RuleList {
        param(
            [Parameter(ValueFromPipeline=$true)]
            $Value
        )

        if ($null -eq $Value) { return '' }
        @($Value | Sort-Object) -join ','
    }

    # Export combined NSG+rule output (one row per rule)
    $ruleRows = foreach ($nsg in $nsgs) {
        # Associations can be $null; normalize to IDs
        $subnetIds = @($nsg.Subnets | ForEach-Object { $_.Id })
        $nicIds    = @($nsg.NetworkInterfaces | ForEach-Object { $_.Id })

        # Shorten association lists for readability (first 2 items)
        $subnetsShort = if ($subnetIds.Count -gt 0) {
            $suffix = ($subnetIds.Count -gt 2) ? ' …' : ''
            (($subnetIds | Select-Object -First 2) -join '; ') + $suffix
        } else { '' }

        $nicsShort = if ($nicIds.Count -gt 0) {
            $suffix = ($nicIds.Count -gt 2) ? ' …' : ''
            (($nicIds | Select-Object -First 2) -join '; ') + $suffix
        } else { '' }

        # Rule counts
        $customRuleCount  = ($nsg.SecurityRules         | Measure-Object).Count
        $defaultRuleCount = ($nsg.DefaultSecurityRules  | Measure-Object).Count
        $totalRuleCount   = $customRuleCount + $defaultRuleCount

        foreach ($rule in @($nsg.SecurityRules)) {
            $sourceAddressList = if ($rule.SourceAddressPrefixes) { $rule.SourceAddressPrefixes } else { $rule.SourceAddressPrefix }
            $destAddressList   = if ($rule.DestinationAddressPrefixes) { $rule.DestinationAddressPrefixes } else { $rule.DestinationAddressPrefix }
            $sourcePortList    = if ($rule.SourcePortRanges) { $rule.SourcePortRanges } else { $rule.SourcePortRange }
            $destPortList      = if ($rule.DestinationPortRanges) { $rule.DestinationPortRanges } else { $rule.DestinationPortRange }

            $sourceAddress = $sourceAddressList | Normalize-RuleList
            $destAddress   = $destAddressList   | Normalize-RuleList
            $sourcePort    = $sourcePortList    | Normalize-RuleList
            $destPort      = $destPortList      | Normalize-RuleList

            $matchKey = (
                @(
                    $nsg.Id,
                    ($rule.Direction | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() }),
                    ($rule.Protocol  | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() }),
                    ($sourceAddress.Trim().ToLowerInvariant()),
                    ($sourcePort.Trim().ToLowerInvariant()),
                    ($destAddress.Trim().ToLowerInvariant()),
                    ($destPort.Trim().ToLowerInvariant())
                ) -join '|'
            )

            [PSCustomObject]@{
                NSGName          = $nsg.Name
                ResourceGroup    = $nsg.ResourceGroupName
                Location         = $nsg.Location
                Rules_Total      = $totalRuleCount
                Rules_Custom     = $customRuleCount
                Rules_Default    = $defaultRuleCount
                AssociatedSubnets = $subnetsShort
                AssociatedNICs    = $nicsShort
                Is_Redundant     = $false
                _MatchKey        = $matchKey
                RuleType         = 'Custom'
                Direction        = $rule.Direction
                Priority         = $rule.Priority
                RuleName         = $rule.Name
                Access           = $rule.Access
                Protocol         = $rule.Protocol
                SourceAddress    = $sourceAddress
                SourcePort       = $sourcePort
                DestinationAddress = $destAddress
                DestinationPort  = $destPort
            }
        }

        foreach ($rule in @($nsg.DefaultSecurityRules)) {
            $sourceAddressList = if ($rule.SourceAddressPrefixes) { $rule.SourceAddressPrefixes } else { $rule.SourceAddressPrefix }
            $destAddressList   = if ($rule.DestinationAddressPrefixes) { $rule.DestinationAddressPrefixes } else { $rule.DestinationAddressPrefix }
            $sourcePortList    = if ($rule.SourcePortRanges) { $rule.SourcePortRanges } else { $rule.SourcePortRange }
            $destPortList      = if ($rule.DestinationPortRanges) { $rule.DestinationPortRanges } else { $rule.DestinationPortRange }

            $sourceAddress = $sourceAddressList | Normalize-RuleList
            $destAddress   = $destAddressList   | Normalize-RuleList
            $sourcePort    = $sourcePortList    | Normalize-RuleList
            $destPort      = $destPortList      | Normalize-RuleList

            $matchKey = (
                @(
                    $nsg.Id,
                    ($rule.Direction | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() }),
                    ($rule.Protocol  | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() }),
                    ($sourceAddress.Trim().ToLowerInvariant()),
                    ($sourcePort.Trim().ToLowerInvariant()),
                    ($destAddress.Trim().ToLowerInvariant()),
                    ($destPort.Trim().ToLowerInvariant())
                ) -join '|'
            )

            [PSCustomObject]@{
                Is_Redundant     = $false
                NSGName          = $nsg.Name
                ResourceGroup    = $nsg.ResourceGroupName
                Location         = $nsg.Location
                Rules_Total      = $totalRuleCount
                Rules_Custom     = $customRuleCount
                Rules_Default    = $defaultRuleCount
                AssociatedSubnets = $subnetsShort
                AssociatedNICs    = $nicsShort
                _MatchKey        = $matchKey
                RuleType         = 'Default'
                Direction        = $rule.Direction
                Priority         = $rule.Priority
                RuleName         = $rule.Name
                Access           = $rule.Access
                Protocol         = $rule.Protocol
                SourceAddress    = $sourceAddress
                SourcePort       = $sourcePort
                DestinationAddress = $destAddress
                DestinationPort  = $destPort
            }
        }

        if ($customRuleCount -eq 0 -and $defaultRuleCount -eq 0) {
            [PSCustomObject]@{
                Is_Redundant     = $false
                NSGName          = $nsg.Name
                ResourceGroup    = $nsg.ResourceGroupName
                Location         = $nsg.Location
                Rules_Total      = $totalRuleCount
                Rules_Custom     = $customRuleCount
                Rules_Default    = $defaultRuleCount
                AssociatedSubnets = $subnetsShort
                AssociatedNICs    = $nicsShort
                _MatchKey        = $null
                RuleType         = ''
                Direction        = ''
                Priority         = ''
                RuleName         = ''
                Access           = ''
                Protocol         = ''
                SourceAddress    = ''
                SourcePort       = ''
                DestinationAddress = ''
                DestinationPort  = ''
            }
        }
    }

    # Mark redundant rules: same direction/protocol/ports/addresses within a single NSG
    $keyCounts = @{}
    foreach ($row in $ruleRows) {
        if ([string]::IsNullOrWhiteSpace($row._MatchKey)) { continue }
        if ($keyCounts.ContainsKey($row._MatchKey)) {
            $keyCounts[$row._MatchKey]++
        } else {
            $keyCounts[$row._MatchKey] = 1
        }
    }
    foreach ($row in $ruleRows) {
        if ([string]::IsNullOrWhiteSpace($row._MatchKey)) {
            $row.Is_Redundant = $false
        } else {
            $row.Is_Redundant = ($keyCounts[$row._MatchKey] -gt 1)
        }
    }
    # Export combined NSG+rule output to CSV (one row per rule)
    $ruleRows |
        Sort-Object ResourceGroup, NSGName, Direction, Priority, RuleType, RuleName |
        Select-Object `
            Is_Redundant,
            NSGName, ResourceGroup, Location, Rules_Total, Rules_Custom, Rules_Default, AssociatedSubnets, AssociatedNICs,
            RuleType, Direction, Priority, Access, Protocol, SourceAddress, SourcePort, DestinationAddress, DestinationPort, RuleName |
        Select-Object -ExcludeProperty _MatchKey |
        Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    Write-Host "`nWrote CSV output:" -ForegroundColor Cyan
    Write-Host "- $CsvPath" -ForegroundColor Cyan

    # Optional: show orphaned NSGs (no subnet/NIC associations)
    $orphaned = $rows | Where-Object { [string]::IsNullOrWhiteSpace($_.AssociatedSubnets) -and [string]::IsNullOrWhiteSpace($_.AssociatedNICs) }
    if ($orphaned) {
        Write-Host "`nOrphaned NSGs (no subnet/NIC associations):" -ForegroundColor Yellow
        $orphaned | Sort-Object ResourceGroup, NSGName | Format-Table -AutoSize NSGName, ResourceGroup, Location
    }

} catch {
    Write-Error "Failed to enumerate NSGs. $($_.Exception.Message)"
    throw
}

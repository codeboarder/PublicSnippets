<#!
.SYNOPSIS
Interactive Azure VM SKU insights tool (series + region + restriction filter).

.DESCRIPTION
Prompts for a VM type category (mapped to common Azure VM series prefixes), an Azure region, and whether to
show restricted or available SKUs. It then queries Azure VM SKUs via Azure CLI (az vm list-skus) and displays
selected capabilities (vCPUs, memory, max NICs, accelerated networking, architecture) in a sorted table.

.PARAMETER None
This script is interactive and does not accept parameters.

.EXAMPLE
./resource_sku_insights.ps1

.NOTES
Requires Azure CLI (az) and access to query VM SKUs. Ensure you are authenticated (az login) and have the
appropriate subscription selected if needed (az account set).
#>

# Stop on errors
$ErrorActionPreference = 'Stop'

# Ensure Azure CLI is available
if (-not (Get-Command -Name az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI (az) not found. Install from https://learn.microsoft.com/cli/azure/ and ensure 'az' is on PATH."
    exit 1
}

try {
    # Output files (written next to this script)
    $OutputDir = $PSScriptRoot
    if (-not $OutputDir) { $OutputDir = (Get-Location).Path }
    $Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $CsvPath = Join-Path $OutputDir "\\output\\sku-export-$Timestamp.csv"

    # Ensure output folder exists
    $csvDir = Split-Path -Parent $CsvPath
    if (-not (Test-Path -Path $csvDir)) {
        New-Item -ItemType Directory -Path $csvDir -Force | Out-Null
    }

# Display VM Type menu
Write-Host "`nAzure VM SKU Query Tool (Detailed)" -ForegroundColor Cyan
Write-Host "==================================`n" -ForegroundColor Cyan

Write-Host "Select VM Type:" -ForegroundColor Yellow
Write-Host "1. General purpose"
Write-Host "2. Compute optimized"
Write-Host "3. Memory optimized"
Write-Host "4. Storage optimized"
Write-Host "5. GPU accelerated"
Write-Host "6. FPGA accelerated"
Write-Host ""

$vmTypeChoice = Read-Host "Enter your choice (1-6)"

# Map VM type selection to Azure VM series prefixes
switch ($vmTypeChoice) {
    "1" {
        $seriesPrefixes = @('Standard_A', 'Standard_B', 'Standard_D')
        $vmTypeName = "General Purpose"
    }
    "2" {
        $seriesPrefixes = @('Standard_F')
        $vmTypeName = "Compute Optimized"
    }
    "3" {
        $seriesPrefixes = @('Standard_E', 'Standard_M')
        $vmTypeName = "Memory Optimized"
    }
    "4" {
        $seriesPrefixes = @('Standard_L')
        $vmTypeName = "Storage Optimized"
    }
    "5" {
        $seriesPrefixes = @('Standard_NC', 'Standard_ND', 'Standard_NV')
        $vmTypeName = "GPU Accelerated"
    }
    "6" {
        $seriesPrefixes = @('Standard_NP')
        $vmTypeName = "FPGA Accelerated"
    }
    default {
        Write-Host "Invalid choice. Defaulting to General Purpose." -ForegroundColor Red
        $seriesPrefixes = @('Standard_A', 'Standard_B', 'Standard_D')
        $vmTypeName = "General Purpose"
    }
}

# Prompt for Azure region
Write-Host "`nEnter Azure Region (programmatic name):" -ForegroundColor Yellow
Write-Host "Examples: eastus, westus2, centralus, westeurope" -ForegroundColor Gray
$region = Read-Host "Region"

# Prompt for restriction filter
Write-Host "`nDo you want to see RESTRICTED VMs? (Yes/No):" -ForegroundColor Yellow
Write-Host "Yes = Show only restricted VMs | No = Show only available VMs" -ForegroundColor Gray
$showRestricted = Read-Host "Choice"

# Build the query filter for VM series
# This creates a JMESPath filter that checks if the name starts with any of the prefixes
$filterConditions = $seriesPrefixes | ForEach-Object { "starts_with(name, '$_')" }
$seriesFilter = $filterConditions -join " || "

# Add restriction filter based on user choice
if ($showRestricted -ieq "Yes" -or $showRestricted -ieq "Y") {
    # Show only restricted VMs (where restrictions array has content)
    $filter = "($seriesFilter) && restrictions && length(restrictions) > ``0``"
    $filterType = "RESTRICTED"
    Write-Host "`nQuerying Azure for RESTRICTED $vmTypeName VMs in region: $region..." -ForegroundColor Green
} else {
    # Show only available VMs (where restrictions array is null or empty)
    $filter = "($seriesFilter) && (!restrictions || length(restrictions) == ``0``)"
    $filterType = "AVAILABLE"
    Write-Host "`nQuerying Azure for AVAILABLE $vmTypeName VMs in region: $region..." -ForegroundColor Green
}

# Execute Azure CLI command with detailed specifications
# Extract vCPUs, Memory, and Network capabilities from the capabilities array
$query = "[?$filter].{Name:name, vCPUs:capabilities[?name=='vCPUs'].value | [0], MemoryGB:capabilities[?name=='MemoryGB'].value | [0], MaxNICs:capabilities[?name=='MaxNetworkInterfaces'].value | [0], AccelNet:capabilities[?name=='AcceleratedNetworkingEnabled'].value | [0], Architecture:capabilities[?name=='CpuArchitectureType'].value | [0], Family:family, Restrictions:restrictions[].type | join(', ', @) || 'None'}"

# Get results as JSON, sort them, then display as table
$results = az vm list-skus --location $region --all --resource-type virtualMachines `
    --query $query `
    --output json | ConvertFrom-Json

if (-not $results -or $results.Count -eq 0) {
    Write-Warning "No SKU results returned for region '$region' ($filterType)."
    return
}

# Normalize types and add context columns for CSV export
$rows = $results | ForEach-Object {
    $_.vCPUs = if ($null -ne $_.vCPUs -and $_.vCPUs -ne '') { [int]$_.vCPUs } else { $null }
    $_.MemoryGB = if ($null -ne $_.MemoryGB -and $_.MemoryGB -ne '') { [int]$_.MemoryGB } else { $null }
    $_.MaxNICs = if ($null -ne $_.MaxNICs -and $_.MaxNICs -ne '') { [int]$_.MaxNICs } else { $null }

    [PSCustomObject]@{
        Location     = $region
        VmType       = $vmTypeName
        FilterType   = $filterType
        Name         = $_.Name
        Restrictions = $_.Restrictions
        vCPUs        = $_.vCPUs
        MemoryGB     = $_.MemoryGB
        MaxNICs      = $_.MaxNICs
        AccelNet     = $_.AccelNet
        Architecture = $_.Architecture
    }
}

$rows |
    Sort-Object vCPUs, MemoryGB, Name |
    Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

Write-Host "`nWrote CSV output:" -ForegroundColor Cyan
Write-Host "- $CsvPath" -ForegroundColor Cyan

} catch {
    Write-Error "Failed to export SKU insights. $($_.Exception.Message)"
    throw
}
<#
Bulk-create Azure Policy exemptions for all currently NonCompliant resources
under a management group for a given policy assignment.

Requires:
  - Az.Accounts
  - Az.PolicyInsights
  - Az.Resources
#>

# ---------------------------
# INPUTS
# ---------------------------
$ManagementGroupName = "myMg"   # e.g., "contoso-platform" (MG display name differs from MG name; use the MG "name")
$PolicyAssignmentId  = "/providers/Microsoft.Management/managementGroups/myMg/providers/Microsoft.Authorization/policyAssignments/limitVMSku"
$ExemptionCategory   = "Waiver"   # "Waiver" or "Mitigated"
$ExpiresOnUtc        = (Get-Date).ToUniversalTime().AddDays(30)  # time-bound recommended
$DisplayNamePrefix   = "Auto exemption"
$Description         = "Auto-created exemption (bulk) - requires follow-up approval"
$WhatIf              = $false     # set $true to test without creating exemptions

# ---------------------------
# AUTH
# ---------------------------
Connect-AzAccount | Out-Null

# Retrieve the assignment object (used by New-AzPolicyExemption)
$assignment = Get-AzPolicyAssignment -Id $PolicyAssignmentId

# IMPORTANT:
# For MG-scoped assignments, -PolicyAssignmentName parameter isn't available in the MG overload,
# but you can filter using OData via -Filter. [2](https://dev.to/omiossec/get-azure-policy-compliance-state-with-powershell-3e7c)[1](https://learn.microsoft.com/en-us/powershell/module/az.policyinsights/get-azpolicystate?view=azps-15.3.0)
#
# The DEV Community example shows filtering by PolicyAssignmentName even when the assignment is MG-scoped. [2](https://dev.to/omiossec/get-azure-policy-compliance-state-with-powershell-3e7c)
# PolicyAssignmentName is typically the assignment's "name" (often a GUID), not the full resource ID.
$PolicyAssignmentName = $assignment.Name

# ---------------------------
# FIND NON-COMPLIANT RESOURCES (MG scope)
# ---------------------------
$filter = "ComplianceState eq 'NonCompliant' and PolicyAssignmentName eq '$PolicyAssignmentName'"

$nonCompliantStates = Get-AzPolicyState `
  -ManagementGroupName $ManagementGroupName `
  -Filter $filter `
  -All

if (-not $nonCompliantStates) {
  Write-Host "No non-compliant resources found for assignment '$PolicyAssignmentName' in MG '$ManagementGroupName'."
  return
}

# Deduplicate by resourceId (policy state can include multiple rows per resource)
$resourceIds = $nonCompliantStates |
  Select-Object -ExpandProperty ResourceId -Unique

Write-Host ("Found {0} unique non-compliant resources." -f $resourceIds.Count)

# ---------------------------
# CREATE EXEMPTIONS
# ---------------------------
$script:PolicyExemptionsByScope = @{}

function Get-PolicyExemptionsForScopeCached {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Scope
  )

  if ($script:PolicyExemptionsByScope.ContainsKey($Scope)) {
    return $script:PolicyExemptionsByScope[$Scope]
  }

  try {
    $result = @(Get-AzPolicyExemption -Scope $Scope -ErrorAction Stop)
    $script:PolicyExemptionsByScope[$Scope] = $result
    return $result
  }
  catch {
    $script:PolicyExemptionsByScope[$Scope] = @()
    return @()
  }
}

function Get-ExistingPolicyExemptionForAssignmentInScope {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Scope,

    [Parameter(Mandatory = $true)]
    [string] $AssignmentId
  )

  foreach ($exemption in (Get-PolicyExemptionsForScopeCached -Scope $Scope)) {
    $exemptionAssignmentId = $null

    if ($exemption.PSObject.Properties.Name -contains 'PolicyAssignmentId') {
      $exemptionAssignmentId = $exemption.PolicyAssignmentId
    }
    elseif ($exemption.PSObject.Properties.Name -contains 'Properties' -and $null -ne $exemption.Properties) {
      if ($exemption.Properties.PSObject.Properties.Name -contains 'PolicyAssignmentId') {
        $exemptionAssignmentId = $exemption.Properties.PolicyAssignmentId
      }
    }

    if ($null -ne $exemptionAssignmentId -and $exemptionAssignmentId -ieq $AssignmentId) {
      return $exemption
    }
  }

  return $null
}

function Get-ExistingPolicyExemptionForAssignmentAffectingResource {
  param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceId,

    [Parameter(Mandatory = $true)]
    [string] $AssignmentId,

    [Parameter(Mandatory = $false)]
    [string] $ManagementGroupName
  )

  $scopesToCheck = New-Object System.Collections.Generic.List[string]

  if ($ManagementGroupName) {
    $scopesToCheck.Add("/providers/Microsoft.Management/managementGroups/$ManagementGroupName") | Out-Null
  }

  if ($ResourceId -match '^(/subscriptions/[^/]+)') {
    $scopesToCheck.Add($Matches[1]) | Out-Null
  }

  if ($ResourceId -match '^(/subscriptions/[^/]+/resourceGroups/[^/]+)') {
    $scopesToCheck.Add($Matches[1]) | Out-Null
  }

  $scopesToCheck.Add($ResourceId) | Out-Null

  foreach ($scope in $scopesToCheck) {
    $existing = Get-ExistingPolicyExemptionForAssignmentInScope -Scope $scope -AssignmentId $AssignmentId
    if ($null -ne $existing) {
      return $existing
    }
  }

  return $null
}

foreach ($resourceId in $resourceIds) {

  # Build a deterministic, length-safe exemption name:
  # exemption name is a simple string; keep it short and unique.
  $shortHash = ([System.BitConverter]::ToString(
      (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash(
        [System.Text.Encoding]::UTF8.GetBytes($resourceId)
      )
    ).Replace("-", "")).Substring(0, 12).ToLower()

  $exemptionName = "autoex-$shortHash"

  # Only create an exemption if one doesn't already exist for this assignment at this resource scope.
  $existingExemption = Get-ExistingPolicyExemptionForAssignmentAffectingResource -ResourceId $resourceId -AssignmentId $PolicyAssignmentId -ManagementGroupName $ManagementGroupName
  if ($null -ne $existingExemption) {
    Write-Host ("Skipping resource because an exemption already exists: resource='{0}', existingExemption='{1}'" -f $resourceId, $existingExemption.Name)
    continue
  }

  if ($WhatIf) {
    Write-Host "[WhatIf] Would create exemption '$exemptionName' for resource: $resourceId"
    continue
  }

  # New-AzPolicyExemption supports scopes including management group, subscription,
  # resource group, OR an individual resource. [3](https://learn.microsoft.com/en-us/powershell/module/az.resources/new-azpolicyexemption?view=azps-15.3.0)[4](https://www.mywebuniversity.com/PowerShell_PDF/New-AzPolicyExemption.pdf)
  New-AzPolicyExemption `
    -Name $exemptionName `
    -PolicyAssignment $assignment `
    -Scope $resourceId `
    -ExemptionCategory $ExemptionCategory `
    -DisplayName ("{0}: {1}" -f $DisplayNamePrefix, $resourceId) `
    -Description $Description `
    -ExpiresOn $ExpiresOnUtc `
    -Metadata (@{
      createdBy = "automation"
      createdOn = (Get-Date).ToUniversalTime().ToString("o")
      mgScope = $ManagementGroupName
      policyAssignmentId = $PolicyAssignmentId
    } | ConvertTo-Json -Compress)

  Write-Host "Created exemption '$exemptionName' for $resourceId"
}
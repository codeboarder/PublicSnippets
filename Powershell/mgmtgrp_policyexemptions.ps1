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
$PolicyAssignmentIds = @(
  "/providers/Microsoft.Management/managementGroups/myMg/providers/Microsoft.Authorization/policyAssignments/limitVMSku"
  # "/providers/Microsoft.Management/managementGroups/myMg/providers/Microsoft.Authorization/policyAssignments/anotherAssignment"
)
$ExemptionCategory   = "Waiver"   # "Waiver" or "Mitigated"
$ExpiresOnUtc        = (Get-Date).ToUniversalTime().AddDays(30)  # time-bound recommended
$DisplayNamePrefix   = "Auto exemption"
$Description         = "Auto-created exemption (bulk) - requires follow-up approval"
$WhatIf              = $false     # set $true to test without creating exemptions

# ---------------------------
# AUTH
# ---------------------------
Connect-AzAccount | Out-Null

if (-not $PolicyAssignmentIds -or $PolicyAssignmentIds.Count -lt 1) {
  throw "No PolicyAssignmentIds provided. Populate $PolicyAssignmentIds with one or more assignment resource IDs."
}

# ---------------------------
# HELPERS (existing exemption detection)
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

# ---------------------------
# PROCESS EACH ASSIGNMENT
# ---------------------------
foreach ($PolicyAssignmentId in $PolicyAssignmentIds) {

  Write-Host ("\nProcessing policy assignment: {0}" -f $PolicyAssignmentId)

  # Retrieve the assignment object (used by New-AzPolicyExemption)
  $assignment = Get-AzPolicyAssignment -Id $PolicyAssignmentId

  # IMPORTANT:
  # For MG-scoped assignments, -PolicyAssignmentName parameter isn't available in the MG overload,
  # but you can filter using OData via -Filter.
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
    continue
  }

  # Deduplicate by resourceId (policy state can include multiple rows per resource)
  $resourceIds = $nonCompliantStates |
    Select-Object -ExpandProperty ResourceId -Unique

  Write-Host ("Found {0} unique non-compliant resources for assignment '{1}'." -f $resourceIds.Count, $PolicyAssignmentName)

  # ---------------------------
  # CREATE EXEMPTIONS
  # ---------------------------
  foreach ($resourceId in $resourceIds) {

    # Build a deterministic, length-safe exemption name:
    # exemption name is a simple string; keep it short and unique.
    $shortHash = ([System.BitConverter]::ToString(
        (New-Object System.Security.Cryptography.SHA256Managed).ComputeHash(
          [System.Text.Encoding]::UTF8.GetBytes("$PolicyAssignmentId|$resourceId")
        )
      ).Replace("-", "")).Substring(0, 12).ToLower()

    $exemptionName = "autoex-$shortHash"

    # Only create an exemption if one doesn't already exist for this assignment affecting this resource.
    $existingExemption = Get-ExistingPolicyExemptionForAssignmentAffectingResource -ResourceId $resourceId -AssignmentId $PolicyAssignmentId -ManagementGroupName $ManagementGroupName
    if ($null -ne $existingExemption) {
      Write-Host ("Skipping resource because an exemption already exists: assignmentId='{0}', resource='{1}', existingExemption='{2}'" -f $PolicyAssignmentId, $resourceId, $existingExemption.Name)
      continue
    }

    if ($WhatIf) {
      Write-Host "[WhatIf] Would create exemption '$exemptionName' for resource: $resourceId (assignmentId='$PolicyAssignmentId')"
      continue
    }

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

    Write-Host "Created exemption '$exemptionName' for $resourceId (assignmentId='$PolicyAssignmentId')"
  }
}
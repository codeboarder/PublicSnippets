# PublicSnippets

My small, self-contained scripts and snippets. This code comes with no guarantees or support of any kind. Use at your own risk!

## Intent

This repo is a grab-bag of small utilities (primarily PowerShell) that can be run independently. Each script is intended to be:

- Self-contained (minimal dependencies beyond common modules)
- Parameter-driven or interactive (no hardcoded subscription IDs, etc.)
- Safe to copy/paste into other repos when needed

## Project structure

See `PowerShell/README.md` for details and usage examples for each script.

```text
PublicSnippets/
  PowerShell/
    fwflowlog_toptalkers.ps1
    subscription_storage_capacityusage.ps1
    subscription_nsg_inventory.ps1
    subscription_quota_insights.ps1
    resource_sku_insights.ps1
    mgmtgrp_policyexemptions.ps1
    /output  # generated CSV exports
```

# Azure VM Scale Test — 5,000 VMs with Pre-Created NICs (Two-Phase Approach)

## Overview

This template deploys **5,000 individual Azure VMs** (not VMSS) using a **two-phase approach**: NICs are created first in isolation, then VMs are deployed referencing the pre-existing NICs. Each VM has 1 OS disk (StandardSSD) and 2 Premium V2 SSD data disks.

This is an evolution of the [original combined approach](../vm-scale-test-5000/) designed to isolate NIC creation from VM creation to study ARM throttling behavior.

## Architecture

```
Phase 1: NIC-Only Deployment
  └─ 20 parallel ARM template batches × 250 NICs = 5,000 NICs

Phase 2: VM-Only Deployment (references pre-existing NICs)
  └─ 20 parallel ARM template batches × 250 VMs = 5,000 VMs
     └─ Each VM: D2ds_v5 + 1 OS Disk + 2 PremiumV2 Data Disks
```

## Key Findings (Run 6)

| Metric | Combined (Run 5) | Pre-NIC (Run 6) |
|--------|-------------------|------------------|
| VMs Created | 5,000 | 4,307 (86%) |
| NIC 429s | 24,343 | 49,893 ↑ |
| VM Phase Duration | 63 min | ~15 min ↓ |
| Total Duration | 63 min | ~12 hrs |

**Conclusion**: The two-phase approach proved that NIC throttling is an inherent ARM rate limit, not caused by VM competition. The combined approach (Run 5) is more effective for this workload because VM dependency chains naturally pace NIC creation.

## Files

| File | Description |
|------|-------------|
| `nic-batch-deploy.json` | NIC-only ARM template (copy loop, 250/batch) |
| `vm-only-batch-deploy.json` | VM-only ARM template (references existing NICs) |
| `azuredeploy.json` | Infrastructure template (VNet, NSG, Subnet) |
| `Deploy-ScaleTest-PreNIC.ps1` | Full orchestration script (7 phases) |
| `Invoke-TelemetryCollection.ps1` | Kusto telemetry collection + HTML reports |
| `Send-ScaleTestReport.ps1` | Email delivery for reports |
| `azure-pipelines.yml` | ADO pipeline (daily cron, 4 stages) |

## Usage

### Manual Run

```powershell
# Full run with cleanup
.\Deploy-ScaleTest-PreNIC.ps1

# Skip cleanup (keep VMs for analysis)
.\Deploy-ScaleTest-PreNIC.ps1 -SkipCleanup

# Skip wait period
.\Deploy-ScaleTest-PreNIC.ps1 -SkipWait
```

### Prerequisites

- Azure PowerShell Az module 11.x+
- Subscription with 10,000 DDSv5 vCPUs quota in EastUS2EUAP
- Logged into Azure (`Connect-AzAccount`)

## Telemetry Clusters

| RP | Cluster | Database | Table |
|----|---------|----------|-------|
| ARM | armprodgbl.eastus.kusto.windows.net | ARMProd | Unionizer("Requests","HttpIncomingRequests") |
| CRP | azcrp.kusto.windows.net | crp_allprod | ApiQosEvent |
| DiskRP | disks.kusto.windows.net | Disks | DiskManagerApiQoSEvent |
| SRP | xcontrolplane.kusto.windows.net | SRP | RegionalSRP_ServiceApiQosEvent |

> **Note**: ARM timestamps have an 8-hour offset from script local time.

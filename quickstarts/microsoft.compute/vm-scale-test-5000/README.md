# Scale Test: Deploy 5000 VMs with Premium V2 SSD Data Disks

![Azure Public Test Date](https://azurequickstartsservice.blob.core.windows.net/badges/quickstarts/microsoft.compute/vm-scale-test-5000/PublicLastTestDate.svg)

## Overview

This template deploys **5000 individual Ubuntu 22.04 LTS VMs** across Azure availability zones using parallel ARM template batch deployments. Each VM is configured with:

- **VM Size**: Standard_D2s_v5 (2 vCPUs, 8 GB RAM)
- **OS Disk**: StandardSSD_LRS (managed)
- **Data Disks**: 2 × 1 GiB Premium V2 SSD (PremiumV2_LRS)

The deployment uses an orchestration script that launches 20 parallel batch deployments (250 VMs each) to achieve the fastest possible provisioning time.

## Architecture

```
Resource Group (TDPR-RG-<random>)
├── VNet (10.0.0.0/12)
│   └── Subnet (10.0.0.0/19 — 8190 usable IPs)
├── NSG (SSH allow)
└── 20 Batch Deployments (parallel)
    ├── Batch-00: 250 VMs (Zone 1) — vm-00000 to vm-00249
    ├── Batch-01: 250 VMs (Zone 2) — vm-00250 to vm-00499
    ├── Batch-02: 250 VMs (Zone 3) — vm-00500 to vm-00749
    ├── ...
    └── Batch-19: 250 VMs (Zone 2) — vm-04750 to vm-04999
```

## Prerequisites

1. **Azure Subscription**: `b883903d-216e-45b3-98b0-058819ec9224` (or your own)
2. **vCPU Quota**: **10,000 vCPUs** for the Dv5 family in `EastUS2EUAP` (or your target region)
3. **Az PowerShell Module**: `Install-Module -Name Az -Scope CurrentUser`
4. **SSH Key Pair**: `ssh-keygen -t rsa -b 4096` (default path: `~/.ssh/id_rsa.pub`)

### Request Quota Increase

```powershell
# Check current quota
Get-AzVMUsage -Location EastUS2EUAP | Where-Object { $_.Name.Value -like "*Dv5*" }
```

If quota is insufficient, request an increase via [Azure Portal](https://portal.azure.com/#blade/Microsoft_Azure_Capacity/QuotaMenuBlade) → Compute → Dv5 Family.

## Usage

### Default Deployment (5000 VMs)

```powershell
.\Deploy-ScaleTest.ps1
```

### Custom Deployment

```powershell
# Deploy 100 VMs for a smaller test
.\Deploy-ScaleTest.ps1 -TotalVmCount 100 -BatchSize 50

# Deploy without cleanup
.\Deploy-ScaleTest.ps1 -SkipCleanup

# Deploy without stabilization wait
.\Deploy-ScaleTest.ps1 -SkipWait

# Custom subscription and region
.\Deploy-ScaleTest.ps1 -SubscriptionId "your-sub-id" -Location "eastus2"
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SubscriptionId` | `f6dd1ce5-...` | Azure subscription ID |
| `Location` | `EastUS2EUAP` | Azure region |
| `TotalVmCount` | `5000` | Total VMs to deploy |
| `BatchSize` | `250` | VMs per batch (max 398) |
| `AdminUsername` | `azurescaletest` | VM admin username |
| `SshPublicKeyPath` | `~/.ssh/id_rsa.pub` | Path to SSH public key |
| `-SkipWait` | `false` | Skip 15-min stabilization wait |
| `-SkipCleanup` | `false` | Skip resource group deletion |

## Template Files

| File | Description |
|------|-------------|
| `azuredeploy.json` | Infrastructure template (VNet, NSG, Subnet) |
| `azuredeploy.parameters.json` | Infrastructure parameters |
| `vm-batch-deploy.json` | VM batch template with copy loops |
| `vm-batch-deploy.parameters.json` | VM batch parameters |
| `Deploy-ScaleTest.ps1` | Orchestration script |

## Execution Phases

1. **Prerequisites Check** — Validates Az module, subscription, SSH key, vCPU quota
2. **Infrastructure Deployment** — Creates resource group, VNet, NSG, Subnet
3. **Parallel VM Batch Deployments** — Launches 20 concurrent ARM deployments
4. **Monitor & Report** — Waits for completion, reports success/failure per batch
5. **Stabilization Wait** — 15-minute wait with VM status checks every 2 minutes
6. **Cleanup** — Deletes the entire resource group

## Manual Cleanup

If the script is interrupted or `-SkipCleanup` was used:

```powershell
Remove-AzResourceGroup -Name "TDPR-RG-<your-suffix>" -Force
```

## Important Notes

- **ARM 800-resource limit**: Each batch creates max 500 resources (250 NICs + 250 VMs), well within the 800 limit
- **Premium V2 SSD**: Requires availability zone assignment — VMs are distributed across zones 1, 2, and 3
- **No public IPs**: VMs are internal-only to maximize provisioning speed and avoid public IP quota limits
- **Cost warning**: 5000 VMs + 10,000 Premium V2 SSD disks generate significant costs — clean up promptly

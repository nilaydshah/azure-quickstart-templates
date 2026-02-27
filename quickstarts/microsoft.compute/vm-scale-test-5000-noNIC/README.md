# 5000 VM Scale Test — No-NIC (Inline NIC Configuration)

## Overview

This scale test deploys **5,000 individual VMs** using `networkInterfaceConfigurations` to create NICs inline as part of VM provisioning. CRP handles NIC creation internally, producing **zero ARM NIC PUT requests** and eliminating the NIC throttling bottleneck found in all prior approaches.

## Key Innovation

| Approach | ARM NIC PUTs | Batch Size | Batches | NIC 429 Errors |
|----------|-------------|------------|---------|----------------|
| Combined (vm-scale-test-5000) | 5,000+ | 250 | 20 | 24K–56K |
| Pre-NIC (vm-scale-test-5000-prenic) | 5,000+ | 250+250 | 20+20 | 49K+ |
| **No-NIC (this folder)** | **0** | **500** | **10** | **0** |

Instead of creating a separate `Microsoft.Network/networkInterfaces` resource, the VM template uses:
```json
"networkProfile": {
    "networkApiVersion": "2022-11-01",
    "networkInterfaceConfigurations": [{
        "name": "nic-config",
        "properties": {
            "primary": true,
            "deleteOption": "Delete",
            "ipConfigurations": [{ "name": "ipconfig1", "properties": { "subnet": { "id": "..." } } }]
        }
    }]
}
```

## VM Configuration

- **VM Size**: Standard_D2ds_v5 (2 vCPUs, 8 GB RAM)
- **OS**: Ubuntu 22.04 LTS Gen2
- **OS Disk**: StandardSSD_LRS
- **Data Disks**: 2 × Premium V2 SSD (PremiumV2_LRS)
- **Zones**: 1 and 3 (zone 2 doesn't support PremiumV2_LRS in EastUS2EUAP)
- **Accelerated Networking**: Disabled
- **NIC**: Inline via `networkInterfaceConfigurations` (CRP-managed)

## Prerequisites

1. **Azure subscription** with 10,000 DDSv5 vCPU quota in EastUS2EUAP
2. **SSH key** at `~/.ssh/id_rsa.pub`
3. **Az PowerShell module** (v11+)

## Usage

```powershell
# Full 5K run with cleanup
.\Deploy-ScaleTest-NoNIC.ps1

# 5K run, skip cleanup for manual inspection
.\Deploy-ScaleTest-NoNIC.ps1 -SkipCleanup

# Quick validation (1 VM)
.\Deploy-ScaleTest-NoNIC.ps1 -TotalVmCount 1 -BatchSize 1 -SkipWait

# Custom batch size
.\Deploy-ScaleTest-NoNIC.ps1 -TotalVmCount 5000 -BatchSize 500
```

## File Structure

| File | Description |
|------|-------------|
| `azuredeploy.json` | Infrastructure template (VNet, NSG, Subnet) |
| `azuredeploy.parameters.json` | Infrastructure parameters |
| `vm-noNIC-batch-deploy.json` | VM batch template with inline NIC config |
| `Deploy-ScaleTest-NoNIC.ps1` | Orchestration script (10 batches × 500 VMs) |
| `metadata.json` | Template metadata |
| `reports/` | Generated HTML reports |

## Telemetry Clusters

| RP | Cluster | Database |
|----|---------|----------|
| ARM | `armprodgbl.eastus.kusto.windows.net` | ARMProd |
| CRP | `azcrp.kusto.windows.net` | crp_allprod |
| DiskRP | `disks.kusto.windows.net` | Disks |
| SRP | `xcontrolplane.kusto.windows.net` | SRP |

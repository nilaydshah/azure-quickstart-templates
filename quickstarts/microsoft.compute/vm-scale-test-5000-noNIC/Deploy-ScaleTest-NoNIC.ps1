<#
.SYNOPSIS
    Deploys 5000 VMs with inline NIC configuration (no separate NIC resources).

.DESCRIPTION
    Scale test orchestration script using networkInterfaceConfigurations to eliminate
    ARM NIC PUT throttling. CRP creates NICs internally as part of VM provisioning.

    With 1 resource per VM (vs 2 in combined approach), batch size doubles to 500,
    requiring only 10 batches instead of 20.

    Phases:
    1. Validate prerequisites (Az module, subscription, vCPU quota)
    2. Create resource group and networking infrastructure
    3. Launch 10 parallel batch deployments (500 VMs each)
    4. Monitor deployment progress and report results
    5. Wait 15 minutes for VM stabilization
    6. Cleanup (delete resource group)

.PARAMETER SubscriptionId
    Azure subscription ID. Default: b883903d-216e-45b3-98b0-058819ec9224

.PARAMETER Location
    Azure region. Default: EastUS2EUAP

.PARAMETER TotalVmCount
    Total number of VMs to deploy. Default: 5000

.PARAMETER BatchSize
    Number of VMs per batch deployment. Default: 500 (max 800)

.PARAMETER AdminUsername
    Admin username for VMs. Default: azurescaletest

.PARAMETER SshPublicKeyPath
    Path to SSH public key file. Default: ~/.ssh/id_rsa.pub

.PARAMETER SkipWait
    Skip the 15-minute stabilization wait after deployment.

.PARAMETER SkipCleanup
    Skip the resource group deletion after the test.

.EXAMPLE
    .\Deploy-ScaleTest-NoNIC.ps1
    Deploys 5000 VMs with inline NIC config and cleans up after 15 minutes.

.EXAMPLE
    .\Deploy-ScaleTest-NoNIC.ps1 -TotalVmCount 1 -BatchSize 1
    Deploys 1 VM for validation testing.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId = "b883903d-216e-45b3-98b0-058819ec9224",
    [string]$Location = "EastUS2EUAP",
    [int]$TotalVmCount = 5000,
    [int]$BatchSize = 500,
    [string]$AdminUsername = "azurescaletest",
    [string]$SshPublicKeyPath = "~/.ssh/id_rsa.pub",
    [switch]$SkipWait,
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfraTemplatePath = Join-Path $ScriptDir "azuredeploy.json"
$VmBatchTemplatePath = Join-Path $ScriptDir "vm-noNIC-batch-deploy.json"

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Phase {
    param([string]$Phase, [string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [$Phase] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [SUCCESS] $Message" -ForegroundColor Green
}

function Write-Failure {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [FAILURE] $Message" -ForegroundColor Red
}

function Write-Info {
    param([string]$Message)
    $timestamp = Get-Date -Format "HH:mm:ss"
    Write-Host "[$timestamp] [INFO] $Message" -ForegroundColor Yellow
}

function Get-RandomString {
    param([int]$Length = 8)
    $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
    -join (1..$Length | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
}

# ============================================================================
# Phase 1: Prerequisites Check
# ============================================================================

Write-Phase "PHASE 1" "Validating prerequisites..."
Write-Info "Approach: NoNIC (inline networkInterfaceConfigurations — CRP-managed NICs)"

# Check Az module
if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
    throw "Az.Compute module is not installed. Run: Install-Module -Name Az -Scope CurrentUser"
}

# Set subscription context
Write-Phase "PHASE 1" "Setting subscription context to $SubscriptionId"
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

# Validate SSH key
$expandedKeyPath = [System.IO.Path]::GetFullPath(($SshPublicKeyPath -replace '^~', $HOME))
if (-not (Test-Path $expandedKeyPath)) {
    throw "SSH public key not found at: $expandedKeyPath. Provide a valid path via -SshPublicKeyPath."
}
$sshPublicKey = (Get-Content $expandedKeyPath -Raw).Trim()
Write-Info "SSH public key loaded from $expandedKeyPath"

# Check vCPU quota
Write-Phase "PHASE 1" "Checking vCPU quota for DDSv5 family in $Location..."
$requiredVCpus = $TotalVmCount * 2
try {
    $usage = Get-AzVMUsage -Location $Location | Where-Object {
        $_.Name.Value -like "*standardDv5Family*" -or $_.Name.Value -like "*StandardDDSv5Family*" -or $_.Name.Value -like "*standardDSv5Family*"
    }
    if ($usage) {
        foreach ($u in $usage) {
            $available = $u.Limit - $u.CurrentValue
            Write-Info "$($u.Name.LocalizedValue): Using $($u.CurrentValue)/$($u.Limit) (Available: $available)"
        }
    }
    Write-Info "Required vCPUs: $requiredVCpus (for $TotalVmCount x Standard_D2ds_v5)"
} catch {
    Write-Info "Could not check quota (non-fatal): $_"
}

# Validate templates exist
if (-not (Test-Path $InfraTemplatePath)) { throw "Infrastructure template not found: $InfraTemplatePath" }
if (-not (Test-Path $VmBatchTemplatePath)) { throw "VM batch template not found: $VmBatchTemplatePath" }

# Pre-load batch template into memory to avoid file locking in parallel execution
$vmBatchTemplateContent = Get-Content $VmBatchTemplatePath -Raw
$vmBatchTemplateObject = $vmBatchTemplateContent | ConvertFrom-Json -AsHashtable

$batchCount = [math]::Ceiling($TotalVmCount / $BatchSize)
$rgName = "TDPR-RG-$(Get-RandomString)"

Write-Success "Prerequisites validated"
Write-Info "Resource Group: $rgName"
Write-Info "Total VMs: $TotalVmCount | Batch Size: $BatchSize | Batches: $batchCount"
Write-Info "Key difference: 0 NIC ARM PUTs (CRP handles NIC creation internally)"

# ============================================================================
# Phase 2: Resource Group & Infrastructure
# ============================================================================

Write-Phase "PHASE 2" "Creating resource group '$rgName' in $Location..."
New-AzResourceGroup -Name $rgName -Location $Location -Force | Out-Null
Write-Success "Resource group created: $rgName"

Write-Phase "PHASE 2" "Deploying networking infrastructure (VNet, NSG, Subnet)..."
$infraDeployment = New-AzResourceGroupDeployment `
    -ResourceGroupName $rgName `
    -Name "infra-deployment" `
    -TemplateFile $InfraTemplatePath `
    -location $Location `
    -ErrorAction Stop

$subnetResourceId = $infraDeployment.Outputs.subnetResourceId.Value
Write-Success "Infrastructure deployed. Subnet: $subnetResourceId"

# ============================================================================
# Phase 3: Parallel VM Batch Deployments (single phase — no NIC phase needed)
# ============================================================================

Write-Phase "PHASE 3" "Launching $batchCount parallel batch deployments (NoNIC — inline NIC config)..."
$deploymentStartTime = Get-Date

$zones = @("1", "3")
$batches = @()
for ($i = 0; $i -lt $batchCount; $i++) {
    $si = $i * $BatchSize
    $cnt = [math]::Min($BatchSize, $TotalVmCount - $si)
    $z = $zones[$i % $zones.Count]
    $dn = "batch-{0:D2}" -f $i
    Write-Info "Queuing ${dn}: VMs ${si}-$($si + $cnt - 1), Zone $z"
    $batches += [PSCustomObject]@{ DeploymentName = $dn; StartIndex = $si; VmCount = $cnt; Zone = $z }
}

$results = $batches | ForEach-Object -ThrottleLimit $batchCount -Parallel {
    $b = $_
    $batchStart = Get-Date
    try {
        $dep = New-AzResourceGroupDeployment `
            -ResourceGroupName $using:rgName `
            -Name $b.DeploymentName `
            -TemplateObject $using:vmBatchTemplateObject `
            -vmCount $b.VmCount `
            -startIndex $b.StartIndex `
            -subnetResourceId $using:subnetResourceId `
            -adminUsername $using:AdminUsername `
            -sshPublicKey $using:sshPublicKey `
            -zone $b.Zone `
            -location $using:Location `
            -ErrorAction Stop
        $batchEnd = Get-Date
        [PSCustomObject]@{
            Name      = $b.DeploymentName
            VmCount   = $b.VmCount
            Zone      = $b.Zone
            StartIdx  = $b.StartIndex
            Status    = "Succeeded"
            Error     = ""
            StartTime = $batchStart
            EndTime   = $batchEnd
            Duration  = ($batchEnd - $batchStart)
        }
    } catch {
        $batchEnd = Get-Date
        [PSCustomObject]@{
            Name      = $b.DeploymentName
            VmCount   = $b.VmCount
            Zone      = $b.Zone
            StartIdx  = $b.StartIndex
            Status    = "Failed"
            Error     = $_.Exception.Message
            StartTime = $batchStart
            EndTime   = $batchEnd
            Duration  = ($batchEnd - $batchStart)
        }
    }
}

Write-Success "All $batchCount batch deployments completed"

# ============================================================================
# Phase 4: Report
# ============================================================================

$deploymentEndTime = Get-Date
$elapsed = $deploymentEndTime - $deploymentStartTime

$succeeded = 0
$failed = 0
$failedBatches = @()

Write-Host ""
Write-Host "=" * 100 -ForegroundColor White
Write-Phase "REPORT" "Per-Batch Deployment Report"
Write-Host "=" * 100 -ForegroundColor White
Write-Host ("{0,-12} {1,-10} {2,-6} {3,-10} {4,-22} {5,-22} {6,-10}" -f "Batch", "Status", "Zone", "VMs", "Start Time", "End Time", "Duration") -ForegroundColor White
Write-Host ("-" * 100) -ForegroundColor Gray

foreach ($r in ($results | Sort-Object Name)) {
    $startStr = $r.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
    $endStr = $r.EndTime.ToString("yyyy-MM-dd HH:mm:ss")
    $durStr = $r.Duration.ToString("mm\:ss")
    $vmRange = "[$($r.StartIdx)-$($r.StartIdx + $r.VmCount - 1)]"

    if ($r.Status -eq "Succeeded") {
        $succeeded++
        Write-Host ("{0,-12} {1,-10} {2,-6} {3,-10} {4,-22} {5,-22} {6,-10}" -f $r.Name, $r.Status, $r.Zone, $vmRange, $startStr, $endStr, $durStr) -ForegroundColor Green
    } else {
        $failed++
        $failedBatches += $r.Name
        Write-Host ("{0,-12} {1,-10} {2,-6} {3,-10} {4,-22} {5,-22} {6,-10}" -f $r.Name, $r.Status, $r.Zone, $vmRange, $startStr, $endStr, $durStr) -ForegroundColor Red
        Write-Host "             Error: $($r.Error)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=" * 100 -ForegroundColor White
Write-Phase "RESULTS" "Deployment Summary"
Write-Host "=" * 100 -ForegroundColor White
Write-Info "Approach:          NoNIC (inline networkInterfaceConfigurations)"
Write-Info "Resource Group:    $rgName"
Write-Info "Subscription:      $SubscriptionId"
Write-Info "Location:          $Location"
Write-Info "Total Batches:     $batchCount"
Write-Info "Succeeded Batches: $succeeded"
Write-Info "Failed Batches:    $failed"
Write-Info "Deploy Start:      $($deploymentStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Info "Deploy End:        $($deploymentEndTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Info "Total Elapsed:     $($elapsed.ToString('mm\:ss'))"
Write-Info "Target:            5:00 (5 minutes)"

if ($results) {
    $successResults = @($results | Where-Object { $_.Status -eq "Succeeded" })
    if ($successResults.Count -gt 0) {
        $minDur = ($successResults | Measure-Object -Property { $_.Duration.TotalSeconds } -Minimum).Minimum
        $maxDur = ($successResults | Measure-Object -Property { $_.Duration.TotalSeconds } -Maximum).Maximum
        $avgDur = ($successResults | Measure-Object -Property { $_.Duration.TotalSeconds } -Average).Average
        Write-Info "Batch Duration (min/avg/max): $([math]::Floor($minDur/60)):$("{0:D2}" -f [int]($minDur%60)) / $([math]::Floor($avgDur/60)):$("{0:D2}" -f [int]($avgDur%60)) / $([math]::Floor($maxDur/60)):$("{0:D2}" -f [int]($maxDur%60))"
    }
}

if ($failedBatches.Count -gt 0) {
    Write-Failure "Failed batches: $($failedBatches -join ', ')"
}

# Resource inventory report
Write-Host ""
Write-Host "=" * 100 -ForegroundColor White
Write-Phase "REPORT" "Resource Inventory"
Write-Host "=" * 100 -ForegroundColor White

try {
    $allResources = @(Get-AzResource -ResourceGroupName $rgName)
    $resourceSummary = $allResources | Group-Object ResourceType | Sort-Object Count -Descending | Select-Object @{N='ResourceType';E={$_.Name}}, Count

    Write-Host ("{0,-55} {1,-10}" -f "Resource Type", "Count") -ForegroundColor White
    Write-Host ("-" * 65) -ForegroundColor Gray
    foreach ($rs in $resourceSummary) {
        Write-Host ("{0,-55} {1,-10}" -f $rs.ResourceType, $rs.Count)
    }
    Write-Host ("-" * 65) -ForegroundColor Gray
    Write-Info "Total Resources:   $($allResources.Count)"
} catch {
    Write-Info "Could not query resources: $_"
}

# VM provisioning state report
Write-Phase "REPORT" "VM Provisioning Status..."
try {
    $vms = @(Get-AzVM -ResourceGroupName $rgName -Status)
    $totalVmsCreated = $vms.Count

    $vmStatusGroups = $vms | Group-Object { "$($_.ProvisioningState) / $($_.PowerState)" } | Sort-Object Count -Descending
    Write-Host ("{0,-40} {1,-10}" -f "Provisioning State / Power State", "Count") -ForegroundColor White
    Write-Host ("-" * 50) -ForegroundColor Gray
    foreach ($g in $vmStatusGroups) {
        Write-Host ("{0,-40} {1,-10}" -f $g.Name, $g.Count)
    }
    Write-Host ("-" * 50) -ForegroundColor Gray
    Write-Info "Total VMs:         $totalVmsCreated"

    # Zone distribution
    $zoneGroups = $vms | Group-Object { $_.Zones -join "," } | Sort-Object Name
    Write-Host ""
    Write-Host ("{0,-15} {1,-10}" -f "Zone", "VM Count") -ForegroundColor White
    Write-Host ("-" * 25) -ForegroundColor Gray
    foreach ($zg in $zoneGroups) {
        Write-Host ("{0,-15} {1,-10}" -f "Zone $($zg.Name)", $zg.Count)
    }
} catch {
    Write-Info "Could not query VM status: $_"
}

# ============================================================================
# Phase 5: Stabilization Wait (15 minutes)
# ============================================================================

if (-not $SkipWait) {
    Write-Phase "PHASE 5" "Waiting 15 minutes for VM stabilization..."
    $waitEnd = (Get-Date).AddMinutes(15)
    $checkInterval = 120

    while ((Get-Date) -lt $waitEnd) {
        $remaining = $waitEnd - (Get-Date)
        $remainingMin = [math]::Floor($remaining.TotalMinutes)
        $remainingSec = $remaining.Seconds

        Write-Info "Stabilization wait: ${remainingMin}m ${remainingSec}s remaining..."

        try {
            $vms = @(Get-AzVM -ResourceGroupName $rgName -Status)
            $running = @($vms | Where-Object { $_.PowerState -eq "VM running" }).Count
            $creating = @($vms | Where-Object { $_.ProvisioningState -eq "Creating" }).Count
            $failedVms = @($vms | Where-Object { $_.ProvisioningState -eq "Failed" }).Count
            $total = $vms.Count

            Write-Info "VM Status - Total: $total | Running: $running | Creating: $creating | Failed: $failedVms"
        } catch {
            Write-Info "Could not query VM status: $_"
        }

        $sleepSeconds = [math]::Min($checkInterval, [math]::Max(1, $remaining.TotalSeconds))
        Start-Sleep -Seconds $sleepSeconds
    }

    Write-Success "Stabilization wait complete"

    try {
        $vms = @(Get-AzVM -ResourceGroupName $rgName -Status)
        $running = @($vms | Where-Object { $_.PowerState -eq "VM running" }).Count
        $failedVms = @($vms | Where-Object { $_.ProvisioningState -eq "Failed" }).Count
        $total = $vms.Count

        Write-Host ""
        Write-Host "=" * 60 -ForegroundColor White
        Write-Phase "FINAL" "Post-Stabilization VM Status"
        Write-Host "=" * 60 -ForegroundColor White
        Write-Info "Total VMs:   $total"
        Write-Info "Running:     $running"
        Write-Info "Failed:      $failedVms"
    } catch {
        Write-Info "Could not query final VM status: $_"
    }
} else {
    Write-Info "Stabilization wait skipped (-SkipWait)"
}

# ============================================================================
# Phase 6: Cleanup
# ============================================================================

if (-not $SkipCleanup) {
    Write-Phase "PHASE 6" "Deleting resource group '$rgName'..."
    $cleanupJob = Remove-AzResourceGroup -Name $rgName -Force -AsJob

    Write-Info "Cleanup initiated. Monitoring deletion progress..."
    $cleanupTimeout = 1800
    $cleanupStart = Get-Date

    while ($cleanupJob.State -eq "Running") {
        $cleanupElapsed = (Get-Date) - $cleanupStart
        if ($cleanupElapsed.TotalSeconds -gt $cleanupTimeout) {
            Write-Failure "Cleanup timed out after 30 minutes. Resource group may still be deleting."
            Write-Info "Check manually: Get-AzResourceGroup -Name $rgName"
            break
        }

        Write-Info "Cleanup in progress... ($([math]::Floor($cleanupElapsed.TotalMinutes))m elapsed)"
        Start-Sleep -Seconds 30
    }

    if ($cleanupJob.State -eq "Completed") {
        try {
            $cleanupJob | Receive-Job -ErrorAction Stop | Out-Null
            Write-Success "Resource group '$rgName' deleted successfully"
        } catch {
            Write-Failure "Cleanup completed with errors: $_"
        }
    } elseif ($cleanupJob.State -eq "Failed") {
        Write-Failure "Cleanup failed. Delete manually: Remove-AzResourceGroup -Name $rgName -Force"
    }

    $cleanupJob | Remove-Job -Force -ErrorAction SilentlyContinue
} else {
    Write-Info "Cleanup skipped (-SkipCleanup). Delete manually when done:"
    Write-Info "  Remove-AzResourceGroup -Name $rgName -Force"
}

Write-Host ""
Write-Host "=" * 60 -ForegroundColor White
Write-Phase "DONE" "Scale test complete (NoNIC approach)"
Write-Host "=" * 60 -ForegroundColor White

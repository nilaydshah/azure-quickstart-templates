<#
.SYNOPSIS
    Deploys 5000 VMs using two-phase approach: NICs first, then VMs.

.DESCRIPTION
    Scale test orchestration script that eliminates ARM NIC throttling by
    separating NIC creation from VM creation:
    Phase 1: Validate prerequisites (Az module, subscription, vCPU quota)
    Phase 2: Create resource group and networking infrastructure
    Phase 3: Create 5000 NICs in parallel batches (no VM competition)
    Phase 4: Create 5000 VMs referencing pre-existing NICs
    Phase 5: Report deployment results
    Phase 6: Wait for VM stabilization (15 min, skippable)
    Phase 7: Cleanup (skippable)

.PARAMETER SubscriptionId
    Azure subscription ID. Default: b883903d-216e-45b3-98b0-058819ec9224

.PARAMETER Location
    Azure region. Default: EastUS2EUAP

.PARAMETER TotalVmCount
    Total number of VMs to deploy. Default: 5000

.PARAMETER NicBatchSize
    Number of NICs per batch deployment. Default: 250

.PARAMETER VmBatchSize
    Number of VMs per batch deployment. Default: 250 (max 398)

.PARAMETER SkipWait
    Skip the 15-minute stabilization wait after deployment.

.PARAMETER SkipCleanup
    Skip the resource group deletion after the test.

.PARAMETER RunId
    Optional run identifier for tracking. Auto-generated if not provided.

.EXAMPLE
    .\Deploy-ScaleTest-PreNIC.ps1 -SkipCleanup
    Deploys 5000 VMs using two-phase approach, skips cleanup.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId = "b883903d-216e-45b3-98b0-058819ec9224",
    [string]$Location = "EastUS2EUAP",
    [int]$TotalVmCount = 5000,
    [int]$NicBatchSize = 250,
    [int]$VmBatchSize = 250,
    [string]$AdminUsername = "azurescaletest",
    [string]$SshPublicKeyPath = "~/.ssh/id_rsa.pub",
    [switch]$SkipWait,
    [switch]$SkipCleanup,
    [string]$RunId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfraTemplatePath = Join-Path $ScriptDir "azuredeploy.json"
$NicBatchTemplatePath = Join-Path $ScriptDir "nic-batch-deploy.json"
$VmBatchTemplatePath = Join-Path $ScriptDir "vm-only-batch-deploy.json"

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

if (-not (Get-Module -ListAvailable -Name Az.Compute)) {
    throw "Az.Compute module is not installed. Run: Install-Module -Name Az -Scope CurrentUser"
}

Write-Phase "PHASE 1" "Setting subscription context to $SubscriptionId"
Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null

$expandedKeyPath = [System.IO.Path]::GetFullPath(($SshPublicKeyPath -replace '^~', $HOME))
if (-not (Test-Path $expandedKeyPath)) {
    throw "SSH public key not found at: $expandedKeyPath"
}
$sshPublicKey = (Get-Content $expandedKeyPath -Raw).Trim()

Write-Phase "PHASE 1" "Checking vCPU quota for DDSv5 family in $Location..."
$requiredVCpus = $TotalVmCount * 2
try {
    $usage = Get-AzVMUsage -Location $Location | Where-Object { $_.Name.Value -like "*StandardDDSv5Family*" }
    if ($usage) {
        $available = $usage.Limit - $usage.CurrentValue
        Write-Info "$($usage.Name.LocalizedValue): Using $($usage.CurrentValue)/$($usage.Limit) (Available: $available)"
        if ($available -lt $requiredVCpus) {
            throw "Insufficient quota: need $requiredVCpus vCPUs, only $available available."
        }
    }
} catch {
    Write-Info "Quota check: $_"
}

if (-not (Test-Path $InfraTemplatePath)) { throw "Infrastructure template not found: $InfraTemplatePath" }
if (-not (Test-Path $NicBatchTemplatePath)) { throw "NIC batch template not found: $NicBatchTemplatePath" }
if (-not (Test-Path $VmBatchTemplatePath)) { throw "VM batch template not found: $VmBatchTemplatePath" }

$nicBatchTemplateObject = (Get-Content $NicBatchTemplatePath -Raw) | ConvertFrom-Json -AsHashtable
$vmBatchTemplateObject = (Get-Content $VmBatchTemplatePath -Raw) | ConvertFrom-Json -AsHashtable

$nicBatchCount = [math]::Ceiling($TotalVmCount / $NicBatchSize)
$vmBatchCount = [math]::Ceiling($TotalVmCount / $VmBatchSize)
$rgName = "TDPR-RG-$(Get-RandomString)"
if (-not $RunId) { $RunId = Get-RandomString -Length 6 }

Write-Success "Prerequisites validated"
Write-Info "Resource Group: $rgName | RunId: $RunId"
Write-Info "Total VMs: $TotalVmCount | NIC Batches: $nicBatchCount ($NicBatchSize/batch) | VM Batches: $vmBatchCount ($VmBatchSize/batch)"

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
# Phase 3: NIC Creation (Two-Phase: NICs First)
# ============================================================================

Write-Phase "PHASE 3" "Launching $nicBatchCount parallel NIC batch deployments..."
$nicStartTime = Get-Date

$nicBatches = @()
for ($i = 0; $i -lt $nicBatchCount; $i++) {
    $si = $i * $NicBatchSize
    $cnt = [math]::Min($NicBatchSize, $TotalVmCount - $si)
    $dn = "nic-batch-{0:D2}" -f $i
    Write-Info "Queuing ${dn}: NICs ${si}-$($si + $cnt - 1)"
    $nicBatches += [PSCustomObject]@{ DeploymentName = $dn; StartIndex = $si; NicCount = $cnt }
}

$nicResults = $nicBatches | ForEach-Object -ThrottleLimit $nicBatchCount -Parallel {
    $b = $_
    $batchStart = Get-Date
    try {
        $dep = New-AzResourceGroupDeployment `
            -ResourceGroupName $using:rgName `
            -Name $b.DeploymentName `
            -TemplateObject $using:nicBatchTemplateObject `
            -nicCount $b.NicCount `
            -startIndex $b.StartIndex `
            -subnetResourceId $using:subnetResourceId `
            -location $using:Location `
            -ErrorAction Stop
        $batchEnd = Get-Date
        [PSCustomObject]@{
            Name     = $b.DeploymentName; NicCount = $b.NicCount; StartIdx = $b.StartIndex
            Status   = "Succeeded"; Error = ""; StartTime = $batchStart; EndTime = $batchEnd
            Duration = ($batchEnd - $batchStart)
        }
    } catch {
        $batchEnd = Get-Date
        [PSCustomObject]@{
            Name     = $b.DeploymentName; NicCount = $b.NicCount; StartIdx = $b.StartIndex
            Status   = "Failed"; Error = $_.Exception.Message; StartTime = $batchStart; EndTime = $batchEnd
            Duration = ($batchEnd - $batchStart)
        }
    }
}

$nicEndTime = Get-Date
$nicElapsed = $nicEndTime - $nicStartTime
$nicSucceeded = @($nicResults | Where-Object { $_.Status -eq "Succeeded" }).Count
$nicFailed = @($nicResults | Where-Object { $_.Status -eq "Failed" }).Count

Write-Host ""
Write-Host "=" * 80 -ForegroundColor White
Write-Phase "NIC REPORT" "NIC Deployment Summary"
Write-Host "=" * 80 -ForegroundColor White
Write-Info "Total NIC Batches: $nicBatchCount | Succeeded: $nicSucceeded | Failed: $nicFailed"
Write-Info "NIC Phase Duration: $($nicElapsed.ToString('mm\:ss'))"

# Verify NIC count
$actualNics = @(Get-AzResource -ResourceGroupName $rgName -ResourceType "Microsoft.Network/networkInterfaces").Count
Write-Info "NICs created: $actualNics / $TotalVmCount"

if ($actualNics -lt $TotalVmCount) {
    Write-Failure "Not all NICs created ($actualNics/$TotalVmCount). VM phase may have failures."
}

# ============================================================================
# Phase 4: VM Creation (referencing pre-existing NICs)
# ============================================================================

Write-Phase "PHASE 4" "Launching $vmBatchCount parallel VM batch deployments (using pre-created NICs)..."
$vmStartTime = Get-Date

$zones = @("1", "3")
$vmBatches = @()
for ($i = 0; $i -lt $vmBatchCount; $i++) {
    $si = $i * $VmBatchSize
    $cnt = [math]::Min($VmBatchSize, $TotalVmCount - $si)
    $z = $zones[$i % $zones.Count]
    $dn = "vm-batch-{0:D2}" -f $i
    Write-Info "Queuing ${dn}: VMs ${si}-$($si + $cnt - 1), Zone $z"
    $vmBatches += [PSCustomObject]@{ DeploymentName = $dn; StartIndex = $si; VmCount = $cnt; Zone = $z }
}

$vmResults = $vmBatches | ForEach-Object -ThrottleLimit $vmBatchCount -Parallel {
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
            Name     = $b.DeploymentName; VmCount = $b.VmCount; Zone = $b.Zone; StartIdx = $b.StartIndex
            Status   = "Succeeded"; Error = ""; StartTime = $batchStart; EndTime = $batchEnd
            Duration = ($batchEnd - $batchStart)
        }
    } catch {
        $batchEnd = Get-Date
        [PSCustomObject]@{
            Name     = $b.DeploymentName; VmCount = $b.VmCount; Zone = $b.Zone; StartIdx = $b.StartIndex
            Status   = "Failed"; Error = $_.Exception.Message; StartTime = $batchStart; EndTime = $batchEnd
            Duration = ($batchEnd - $batchStart)
        }
    }
}

$vmEndTime = Get-Date
$vmElapsed = $vmEndTime - $vmStartTime

# ============================================================================
# Phase 5: Report
# ============================================================================

$totalElapsed = $vmEndTime - $nicStartTime
$vmSucceeded = 0; $vmFailed = 0; $failedBatches = @()

Write-Host ""
Write-Host "=" * 100 -ForegroundColor White
Write-Phase "REPORT" "Per-Batch VM Deployment Report"
Write-Host "=" * 100 -ForegroundColor White
Write-Host ("{0,-14} {1,-10} {2,-6} {3,-10} {4,-22} {5,-22} {6,-10}" -f "Batch", "Status", "Zone", "VMs", "Start Time", "End Time", "Duration") -ForegroundColor White
Write-Host ("-" * 100) -ForegroundColor Gray

foreach ($r in ($vmResults | Sort-Object Name)) {
    $startStr = $r.StartTime.ToString("yyyy-MM-dd HH:mm:ss")
    $endStr = $r.EndTime.ToString("yyyy-MM-dd HH:mm:ss")
    $durStr = $r.Duration.ToString("mm\:ss")
    $vmRange = "[$($r.StartIdx)-$($r.StartIdx + $r.VmCount - 1)]"

    if ($r.Status -eq "Succeeded") {
        $vmSucceeded++
        Write-Host ("{0,-14} {1,-10} {2,-6} {3,-10} {4,-22} {5,-22} {6,-10}" -f $r.Name, $r.Status, $r.Zone, $vmRange, $startStr, $endStr, $durStr) -ForegroundColor Green
    } else {
        $vmFailed++
        $failedBatches += $r.Name
        Write-Host ("{0,-14} {1,-10} {2,-6} {3,-10} {4,-22} {5,-22} {6,-10}" -f $r.Name, $r.Status, $r.Zone, $vmRange, $startStr, $endStr, $durStr) -ForegroundColor Red
        Write-Host "               Error: $($r.Error)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "=" * 100 -ForegroundColor White
Write-Phase "RESULTS" "Deployment Summary"
Write-Host "=" * 100 -ForegroundColor White
Write-Info "Resource Group:      $rgName"
Write-Info "RunId:               $RunId"
Write-Info "Subscription:        $SubscriptionId"
Write-Info "Location:            $Location"
Write-Info "Approach:            Two-Phase (Pre-created NICs)"
Write-Info "NIC Phase Duration:  $($nicElapsed.ToString('mm\:ss'))"
Write-Info "VM Phase Duration:   $($vmElapsed.ToString('mm\:ss'))"
Write-Info "Total Elapsed:       $($totalElapsed.ToString('mm\:ss'))"
Write-Info "NIC Batches:         $nicBatchCount ($nicSucceeded OK, $nicFailed failed)"
Write-Info "VM Batches:          $vmBatchCount ($vmSucceeded OK, $vmFailed failed)"

# Resource inventory
Write-Host ""
Write-Host "=" * 80 -ForegroundColor White
Write-Phase "REPORT" "Resource Inventory"
Write-Host "=" * 80 -ForegroundColor White
try {
    $allResources = @(Get-AzResource -ResourceGroupName $rgName)
    $resourceSummary = $allResources | Group-Object ResourceType | Sort-Object Count -Descending
    foreach ($rs in $resourceSummary) {
        Write-Host "  $($rs.Name): $($rs.Count)"
    }
    Write-Info "Total Resources: $($allResources.Count)"
} catch {
    Write-Info "Could not query resources: $_"
}

# Output JSON results for pipeline consumption
$resultJson = @{
    RunId           = $RunId
    ResourceGroup   = $rgName
    SubscriptionId  = $SubscriptionId
    Location        = $Location
    TotalVmCount    = $TotalVmCount
    Approach        = "Two-Phase-PreNIC"
    NicPhaseDuration = $nicElapsed.TotalSeconds
    VmPhaseDuration  = $vmElapsed.TotalSeconds
    TotalDuration    = $totalElapsed.TotalSeconds
    NicBatchesOk     = $nicSucceeded
    NicBatchesFailed = $nicFailed
    VmBatchesOk      = $vmSucceeded
    VmBatchesFailed  = $vmFailed
    StartTime        = $nicStartTime.ToUniversalTime().ToString("o")
    EndTime          = $vmEndTime.ToUniversalTime().ToString("o")
} | ConvertTo-Json -Depth 3

$resultsPath = Join-Path $ScriptDir "reports" "run-$RunId-results.json"
if (-not (Test-Path (Join-Path $ScriptDir "reports"))) {
    New-Item -ItemType Directory -Path (Join-Path $ScriptDir "reports") -Force | Out-Null
}
$resultJson | Set-Content $resultsPath -Encoding UTF8
Write-Info "Results saved to: $resultsPath"

# ============================================================================
# Phase 6: Stabilization Wait
# ============================================================================

if (-not $SkipWait) {
    Write-Phase "PHASE 6" "Waiting 15 minutes for VM stabilization..."
    Start-Sleep -Seconds 900
    Write-Success "Stabilization wait complete"
}

# ============================================================================
# Phase 7: Cleanup
# ============================================================================

if (-not $SkipCleanup) {
    Write-Phase "PHASE 7" "Deleting resource group '$rgName'..."
    Remove-AzResourceGroup -Name $rgName -Force
    Write-Success "Resource group '$rgName' deleted"
} else {
    Write-Info "Cleanup skipped (-SkipCleanup). Resource group '$rgName' still exists."
}

Write-Host ""
Write-Success "Scale test complete! RunId: $RunId | RG: $rgName | Duration: $($totalElapsed.ToString('mm\:ss'))"

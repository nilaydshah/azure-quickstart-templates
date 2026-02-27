<#
.SYNOPSIS
    Deploys 5000 VMs across availability zones using parallel ARM template batch deployments.

.DESCRIPTION
    Scale test orchestration script that:
    1. Validates prerequisites (Az module, subscription, vCPU quota)
    2. Creates resource group and networking infrastructure
    3. Launches 20 parallel batch deployments (250 VMs each)
    4. Monitors deployment progress and reports results
    5. Waits 15 minutes for VM stabilization
    6. Cleans up all resources by deleting the resource group

    Each VM is Standard_D2s_v5 with Ubuntu 22.04 LTS, 1 OS disk (StandardSSD_LRS),
    and 2 Premium V2 SSD data disks (1 GiB each).

.PARAMETER SubscriptionId
    Azure subscription ID. Default: b883903d-216e-45b3-98b0-058819ec9224

.PARAMETER Location
    Azure region. Default: EastUS2EUAP

.PARAMETER TotalVmCount
    Total number of VMs to deploy. Default: 5000

.PARAMETER BatchSize
    Number of VMs per batch deployment. Default: 250 (max 398)

.PARAMETER AdminUsername
    Admin username for VMs. Default: azurescaletest

.PARAMETER SshPublicKeyPath
    Path to SSH public key file. Default: ~/.ssh/id_rsa.pub

.PARAMETER SkipWait
    Skip the 15-minute stabilization wait after deployment.

.PARAMETER SkipCleanup
    Skip the resource group deletion after the test.

.EXAMPLE
    .\Deploy-ScaleTest.ps1
    Deploys 5000 VMs with default settings and cleans up after 15 minutes.

.EXAMPLE
    .\Deploy-ScaleTest.ps1 -SkipCleanup
    Deploys 5000 VMs but does not delete the resource group afterward.

.EXAMPLE
    .\Deploy-ScaleTest.ps1 -TotalVmCount 100 -BatchSize 50
    Deploys 100 VMs in 2 batches for a smaller test run.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId = "b883903d-216e-45b3-98b0-058819ec9224",
    [string]$Location = "EastUS2EUAP",
    [int]$TotalVmCount = 5000,
    [int]$BatchSize = 250,
    [string]$AdminUsername = "azurescaletest",
    [string]$SshPublicKeyPath = "~/.ssh/id_rsa.pub",
    [switch]$SkipWait,
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$InfraTemplatePath = Join-Path $ScriptDir "azuredeploy.json"
$VmBatchTemplatePath = Join-Path $ScriptDir "vm-batch-deploy.json"

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
Write-Phase "PHASE 1" "Checking vCPU quota for Dv5 family in $Location..."
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
    Write-Info "Required vCPUs: $requiredVCpus (for $TotalVmCount x Standard_D2s_v5)"
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
# Phase 3: Parallel VM Batch Deployments
# ============================================================================

Write-Phase "PHASE 3" "Launching $batchCount parallel batch deployments..."
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

# Per-batch report
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
    $checkInterval = 120  # Check every 2 minutes

    while ((Get-Date) -lt $waitEnd) {
        $remaining = $waitEnd - (Get-Date)
        $remainingMin = [math]::Floor($remaining.TotalMinutes)
        $remainingSec = $remaining.Seconds

        Write-Info "Stabilization wait: ${remainingMin}m ${remainingSec}s remaining..."

        # Periodic VM status check
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

    # Final status
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
# Phase 5B: Generate Detailed Report File
# ============================================================================

Write-Phase "REPORT-FILE" "Generating detailed deployment report..."

function Esc([string]$t) { $t.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;') }

$reportsDir = Join-Path $ScriptDir "reports"
if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }

$reportTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reportPath = Join-Path $reportsDir "ScaleTestReport-${rgName}-${reportTimestamp}.html"

try {
    # Collect post-stabilization data
    $reportVms = @()
    $reportResources = @()
    $batchOpsData = [ordered]@{}

    try {
        Write-Info "Querying VMs for report..."
        $reportVms = @(Get-AzVM -ResourceGroupName $rgName -Status)
    } catch { Write-Info "Could not query VMs: $_" }

    try {
        Write-Info "Querying resources for report..."
        $reportResources = @(Get-AzResource -ResourceGroupName $rgName)
    } catch { Write-Info "Could not query resources: $_" }

    Write-Info "Querying deployment operations per batch..."
    foreach ($r in ($results | Sort-Object Name)) {
        try {
            $ops = @(Get-AzResourceGroupDeploymentOperation -ResourceGroupName $rgName -DeploymentName $r.Name -ErrorAction SilentlyContinue)
            $batchOpsData[$r.Name] = $ops
        } catch {
            $batchOpsData[$r.Name] = @()
        }
    }

    # Calculate metrics
    $totalVmsCreated = $reportVms.Count
    $runningVms = @($reportVms | Where-Object { $_.PowerState -eq "VM running" }).Count
    $failedVmsList = @($reportVms | Where-Object { $_.ProvisioningState -eq "Failed" })
    $successRate = if ($TotalVmCount -gt 0) { [math]::Round(($totalVmsCreated / $TotalVmCount) * 100, 1) } else { 0 }
    $vmSuccessRate = if ($totalVmsCreated -gt 0) { [math]::Round(($runningVms / $totalVmsCreated) * 100, 1) } else { 0 }
    $succeededBatches = @($results | Where-Object { $_.Status -eq "Succeeded" }).Count
    $failedBatchCount = @($results | Where-Object { $_.Status -eq "Failed" }).Count
    $resourceSummary = $reportResources | Group-Object ResourceType | Sort-Object Count -Descending
    $vmStatusSummary = $reportVms | Group-Object { "$($_.ProvisioningState) / $($_.PowerState)" } | Sort-Object Count -Descending
    $zoneDist = $reportVms | Group-Object { $_.Zones -join "," } | Sort-Object Name

    $sb = [System.Text.StringBuilder]::new(65536)

    # ---- HTML Head & CSS ----
    [void]$sb.AppendLine(@"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Scale Test Report - $rgName</title>
<style>
*{box-sizing:border-box}
body{font-family:'Segoe UI',Tahoma,Geneva,Verdana,sans-serif;margin:0;padding:20px;background:#f0f2f5;color:#333}
.container{max-width:1300px;margin:0 auto}
.card{background:#fff;border-radius:8px;box-shadow:0 1px 3px rgba(0,0,0,.12);padding:24px;margin-bottom:20px}
h1{color:#0078d4;margin:0 0 5px;font-size:28px}
h2{color:#0078d4;border-bottom:2px solid #0078d4;padding-bottom:8px;margin-top:0}
h3{margin-top:0}
.subtitle{color:#666;font-size:14px;margin-bottom:20px}
.metrics{display:flex;flex-wrap:wrap;gap:15px;margin:20px 0}
.mc{background:#f8f9fa;border:1px solid #e0e0e0;border-radius:8px;padding:16px 24px;text-align:center;min-width:150px;flex:1}
.mc.hl{border-color:#0078d4;background:#f0f6ff}
.mc.ok{border-color:#107c10;background:#f0fff0}
.mc.bad{border-color:#d13438;background:#fff5f5}
.mv{font-size:32px;font-weight:700;color:#0078d4}
.mc.ok .mv{color:#107c10} .mc.bad .mv{color:#d13438}
.ml{font-size:11px;color:#666;text-transform:uppercase;letter-spacing:.5px;margin-top:4px}
table{border-collapse:collapse;width:100%;margin:10px 0;font-size:14px}
th{background:#0078d4;color:#fff;padding:10px 12px;text-align:left;font-weight:600;white-space:nowrap}
td{padding:8px 12px;border-bottom:1px solid #eee;vertical-align:top}
tr:nth-child(even){background:#fafafa}
tr:hover{background:#f0f6ff}
.sg{color:#107c10;font-weight:600} .sf{color:#d13438;font-weight:600}
.ebox{background:#fdf3f3;border-left:4px solid #d13438;padding:10px 14px;margin:6px 0;font-size:13px;border-radius:0 4px 4px 0;word-break:break-word}
details{margin:8px 0} summary{cursor:pointer;font-weight:600;color:#0078d4;padding:4px 0}
.cg{display:grid;grid-template-columns:200px 1fr;gap:4px 16px;font-size:14px}
.cl{font-weight:600;color:#555} .cv{color:#333}
.badge{display:inline-block;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:600}
.b-ok{background:#dff6dd;color:#107c10} .b-fail{background:#fde7e9;color:#d13438} .b-info{background:#e5f1fb;color:#0078d4}
.footer{text-align:center;color:#999;font-size:12px;margin-top:30px;padding:15px}
</style>
</head>
<body>
<div class="container">
"@)

    # ---- Executive Summary ----
    [void]$sb.AppendLine(@"
<div class="card">
  <h1>&#9729; Azure Scale Test Report</h1>
  <div class="subtitle">Resource Group: <strong>$rgName</strong> &bull; Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
  <div class="metrics">
    <div class="mc hl"><div class="mv">$TotalVmCount</div><div class="ml">Target VMs</div></div>
    <div class="mc $(if($totalVmsCreated -eq $TotalVmCount){'ok'}else{'bad'})"><div class="mv">$totalVmsCreated</div><div class="ml">VMs Created</div></div>
    <div class="mc ok"><div class="mv">$runningVms</div><div class="ml">VMs Running</div></div>
    <div class="mc $(if($failedVmsList.Count -eq 0){'ok'}else{'bad'})"><div class="mv">$($failedVmsList.Count)</div><div class="ml">VMs Failed</div></div>
    <div class="mc $(if($successRate -ge 95){'ok'}else{'bad'})"><div class="mv">${successRate}%</div><div class="ml">Creation Rate</div></div>
    <div class="mc hl"><div class="mv">$($elapsed.ToString('mm\:ss'))</div><div class="ml">Deploy Time</div></div>
  </div>
</div>
"@)

    # ---- Configuration ----
    [void]$sb.AppendLine(@"
<div class="card">
  <h2>&#9881; Deployment Configuration</h2>
  <div class="cg">
    <div class="cl">Subscription ID</div><div class="cv"><code>$SubscriptionId</code></div>
    <div class="cl">Resource Group</div><div class="cv">$rgName</div>
    <div class="cl">Location</div><div class="cv">$Location</div>
    <div class="cl">VM Size</div><div class="cv">Standard_D2ds_v5 (2 vCPUs, 8 GB RAM)</div>
    <div class="cl">OS Image</div><div class="cv">Ubuntu 22.04 LTS Gen2 (Canonical)</div>
    <div class="cl">OS Disk</div><div class="cv">StandardSSD_LRS (image default size)</div>
    <div class="cl">Data Disks</div><div class="cv">2 x PremiumV2_LRS, 1 GiB each</div>
    <div class="cl">Availability Zones</div><div class="cv">Zone 1, Zone 3</div>
    <div class="cl">Accelerated Networking</div><div class="cv">Disabled</div>
    <div class="cl">Total VMs</div><div class="cv">$TotalVmCount</div>
    <div class="cl">Batch Size</div><div class="cv">$BatchSize VMs per batch</div>
    <div class="cl">Total Batches</div><div class="cv">$batchCount</div>
    <div class="cl">Deploy Start</div><div class="cv">$($deploymentStartTime.ToString('yyyy-MM-dd HH:mm:ss'))</div>
    <div class="cl">Deploy End</div><div class="cv">$($deploymentEndTime.ToString('yyyy-MM-dd HH:mm:ss'))</div>
    <div class="cl">Total Duration</div><div class="cv">$($elapsed.ToString('hh\:mm\:ss'))</div>
  </div>
</div>
"@)

    # ---- Per-Batch Deployment Details ----
    [void]$sb.AppendLine(@"
<div class="card">
  <h2>&#128230; Per-Batch Deployment Details</h2>
  <table>
    <thead><tr><th>Batch</th><th>Zone</th><th>VM Range</th><th>Start Time</th><th>End Time</th><th>Duration</th><th>Status</th><th>Ops OK</th><th>Ops Fail</th><th>Error</th></tr></thead>
    <tbody>
"@)

    foreach ($r in ($results | Sort-Object Name)) {
        $startStr = $r.StartTime.ToString("HH:mm:ss")
        $endStr = $r.EndTime.ToString("HH:mm:ss")
        $durStr = $r.Duration.ToString("mm\:ss")
        $vmRange = "$($r.StartIdx)-$($r.StartIdx + $r.VmCount - 1)"
        $statusBadge = if ($r.Status -eq "Succeeded") { "<span class='badge b-ok'>Succeeded</span>" } else { "<span class='badge b-fail'>Failed</span>" }

        $batchOps = $batchOpsData[$r.Name]
        $opsOk = 0; $opsFail = 0
        if ($batchOps -and $batchOps.Count -gt 0) {
            $opsOk = @($batchOps | Where-Object { $_.ProvisioningState -eq "Succeeded" }).Count
            $opsFail = @($batchOps | Where-Object { $_.ProvisioningState -eq "Failed" }).Count
        }

        $errorCell = ""
        if ($r.Status -eq "Failed" -and $r.Error) {
            $truncErr = if ($r.Error.Length -gt 120) { $r.Error.Substring(0,120) + "..." } else { $r.Error }
            $errorCell = "<span style='color:#d13438;font-size:12px'>$(Esc $truncErr)</span>"
        }

        [void]$sb.AppendLine("    <tr><td><strong>$($r.Name)</strong></td><td>$($r.Zone)</td><td>$vmRange</td><td>$startStr</td><td>$endStr</td><td>$durStr</td><td>$statusBadge</td><td>$opsOk</td><td>$opsFail</td><td>$errorCell</td></tr>")
    }

    [void]$sb.AppendLine("    </tbody></table>")

    # Batch duration stats
    if ($results -and @($results).Count -gt 0) {
        $durations = @($results) | ForEach-Object { $_.Duration.TotalSeconds }
        $minD = ($durations | Measure-Object -Minimum).Minimum
        $maxD = ($durations | Measure-Object -Maximum).Maximum
        $avgD = ($durations | Measure-Object -Average).Average
        [void]$sb.AppendLine("  <p><strong>Batch Duration Stats:</strong> Min: $([math]::Floor($minD/60))m$("{0:D2}" -f [int]($minD%60))s &bull; Avg: $([math]::Floor($avgD/60))m$("{0:D2}" -f [int]($avgD%60))s &bull; Max: $([math]::Floor($maxD/60))m$("{0:D2}" -f [int]($maxD%60))s</p>")
    }
    [void]$sb.AppendLine("</div>")

    # ---- Failure Analysis (only for failed batches) ----
    $failedResults = @($results | Where-Object { $_.Status -eq "Failed" })
    if ($failedResults.Count -gt 0) {
        [void]$sb.AppendLine("<div class='card'><h2>&#10060; Failure Analysis</h2>")

        foreach ($fr in ($failedResults | Sort-Object Name)) {
            $batchOps = $batchOpsData[$fr.Name]
            $failedOps = @()
            if ($batchOps) { $failedOps = @($batchOps | Where-Object { $_.ProvisioningState -eq "Failed" }) }

            [void]$sb.AppendLine("  <details open><summary>$($fr.Name) &mdash; Zone $($fr.Zone) &mdash; $($failedOps.Count) failed operations</summary>")

            if ($fr.Error) {
                [void]$sb.AppendLine("  <div class='ebox'><strong>Deployment Error:</strong> $(Esc $fr.Error)</div>")
            }

            if ($failedOps.Count -gt 0) {
                [void]$sb.AppendLine("  <table><thead><tr><th>Resource</th><th>Type</th><th>Error</th></tr></thead><tbody>")
                $errorGroups = $failedOps | Group-Object {
                    $msg = $_.StatusMessage
                    if ($msg -is [string]) { if ($msg.Length -gt 200) { $msg.Substring(0,200) } else { $msg } } else { try { ($msg | ConvertTo-Json -Compress -Depth 2).Substring(0, [math]::Min(200, ($msg | ConvertTo-Json -Compress -Depth 2).Length)) } catch { "$msg" } }
                }
                foreach ($eg in $errorGroups) {
                    $sampleOp = $eg.Group[0]
                    $tr = $sampleOp.TargetResource
                    $resName = if ($tr) { ($tr -split '/')[-1] } else { "N/A" }
                    $resType = if ($tr -like "*virtualMachines*") { "VirtualMachine" } elseif ($tr -like "*networkInterfaces*") { "NIC" } elseif ($tr -like "*disks*") { "Disk" } else { "Other" }
                    $errMsg = $eg.Name
                    if ($errMsg.Length -gt 400) { $errMsg = $errMsg.Substring(0,400) + "..." }
                    $countLabel = if ($eg.Count -gt 1) { " <span class='badge b-fail'>x$($eg.Count) resources</span>" } else { "" }
                    [void]$sb.AppendLine("    <tr><td>$(Esc $resName)$countLabel</td><td><code>$(Esc $resType)</code></td><td style='font-size:12px'>$(Esc $errMsg)</td></tr>")
                }
                [void]$sb.AppendLine("  </tbody></table>")
            }
            [void]$sb.AppendLine("  </details>")
        }
        [void]$sb.AppendLine("</div>")
    }

    # ---- Deployment Operations Summary per Batch ----
    [void]$sb.AppendLine("<div class='card'><h2>&#128295; Deployment Operations Summary</h2>")
    [void]$sb.AppendLine("<table><thead><tr><th>Batch</th><th>Total Ops</th><th>Succeeded</th><th>Failed</th><th>Running</th><th>Other</th><th>NICs OK</th><th>NICs Fail</th><th>VMs OK</th><th>VMs Fail</th></tr></thead><tbody>")

    foreach ($r in ($results | Sort-Object Name)) {
        $batchOps = $batchOpsData[$r.Name]
        $totalOps = if ($batchOps) { $batchOps.Count } else { 0 }
        $okOps = if ($batchOps) { @($batchOps | Where-Object { $_.ProvisioningState -eq "Succeeded" }).Count } else { 0 }
        $failOps = if ($batchOps) { @($batchOps | Where-Object { $_.ProvisioningState -eq "Failed" }).Count } else { 0 }
        $runOps = if ($batchOps) { @($batchOps | Where-Object { $_.ProvisioningState -eq "Running" }).Count } else { 0 }
        $otherOps = $totalOps - $okOps - $failOps - $runOps

        $nicsOk = 0; $nicsFail = 0; $vmsOk = 0; $vmsFail = 0
        if ($batchOps) {
            $nicsOk = @($batchOps | Where-Object { $_.TargetResource -like "*networkInterfaces*" -and $_.ProvisioningState -eq "Succeeded" }).Count
            $nicsFail = @($batchOps | Where-Object { $_.TargetResource -like "*networkInterfaces*" -and $_.ProvisioningState -eq "Failed" }).Count
            $vmsOk = @($batchOps | Where-Object { $_.TargetResource -like "*virtualMachines*" -and $_.ProvisioningState -eq "Succeeded" }).Count
            $vmsFail = @($batchOps | Where-Object { $_.TargetResource -like "*virtualMachines*" -and $_.ProvisioningState -eq "Failed" }).Count
        }

        $failClass = if ($failOps -gt 0) { " class='sf'" } else { "" }
        [void]$sb.AppendLine("    <tr><td><strong>$($r.Name)</strong></td><td>$totalOps</td><td class='sg'>$okOps</td><td$failClass>$failOps</td><td>$runOps</td><td>$otherOps</td><td>$nicsOk</td><td>$nicsFail</td><td>$vmsOk</td><td>$vmsFail</td></tr>")
    }
    [void]$sb.AppendLine("</tbody></table></div>")

    # ---- Resource Inventory ----
    [void]$sb.AppendLine("<div class='card'><h2>&#128451; Resource Inventory</h2>")
    [void]$sb.AppendLine("<table><thead><tr><th>Resource Type</th><th>Count</th></tr></thead><tbody>")
    foreach ($rs in $resourceSummary) {
        [void]$sb.AppendLine("    <tr><td>$($rs.Name)</td><td><strong>$($rs.Count)</strong></td></tr>")
    }
    [void]$sb.AppendLine("</tbody></table>")
    [void]$sb.AppendLine("<p><strong>Total Resources:</strong> $($reportResources.Count)</p></div>")

    # ---- VM Status ----
    [void]$sb.AppendLine(@"
<div class="card">
  <h2>&#128187; VM Provisioning Status</h2>
  <div style="display:flex;gap:40px;flex-wrap:wrap">
    <div><h3>By State</h3>
      <table style="width:auto"><thead><tr><th>Provisioning / Power State</th><th>Count</th></tr></thead><tbody>
"@)
    foreach ($g in $vmStatusSummary) {
        $sc = if ($g.Name -match "Running") { "sg" } elseif ($g.Name -match "Failed") { "sf" } else { "" }
        [void]$sb.AppendLine("        <tr><td class='$sc'>$($g.Name)</td><td><strong>$($g.Count)</strong></td></tr>")
    }
    [void]$sb.AppendLine("      </tbody></table></div>")

    [void]$sb.AppendLine("    <div><h3>By Zone</h3><table style='width:auto'><thead><tr><th>Zone</th><th>VM Count</th></tr></thead><tbody>")
    foreach ($zg in $zoneDist) {
        [void]$sb.AppendLine("        <tr><td>Zone $($zg.Name)</td><td><strong>$($zg.Count)</strong></td></tr>")
    }
    [void]$sb.AppendLine("      </tbody></table></div></div>")
    [void]$sb.AppendLine("  <p><strong>Total VMs:</strong> $totalVmsCreated &bull; <strong>Running:</strong> $runningVms ($vmSuccessRate%) &bull; <strong>Failed:</strong> $($failedVmsList.Count)</p></div>")

    # ---- Failed VMs ----
    if ($failedVmsList.Count -gt 0) {
        [void]$sb.AppendLine("<div class='card'><h2>&#9888; Failed VMs</h2>")
        [void]$sb.AppendLine("<table><thead><tr><th>VM Name</th><th>Provisioning State</th><th>Power State</th><th>Zone</th></tr></thead><tbody>")
        foreach ($fvm in ($failedVmsList | Sort-Object Name)) {
            $z = if ($fvm.Zones) { $fvm.Zones -join "," } else { "N/A" }
            [void]$sb.AppendLine("    <tr><td>$($fvm.Name)</td><td class='sf'>$($fvm.ProvisioningState)</td><td>$($fvm.PowerState)</td><td>$z</td></tr>")
        }
        [void]$sb.AppendLine("</tbody></table></div>")
    }

    # ---- Timeline ----
    [void]$sb.AppendLine("<div class='card'><h2>&#128337; Deployment Timeline</h2>")
    [void]$sb.AppendLine("<table><thead><tr><th>Time</th><th>Event</th><th>Duration</th></tr></thead><tbody>")
    [void]$sb.AppendLine("    <tr><td>$($deploymentStartTime.ToString('HH:mm:ss'))</td><td><span class='badge b-info'>START</span> Launched $batchCount parallel batch deployments</td><td>&mdash;</td></tr>")

    foreach ($r in ($results | Sort-Object EndTime)) {
        $icon = if ($r.Status -eq "Succeeded") { "<span class='badge b-ok'>OK</span>" } else { "<span class='badge b-fail'>FAIL</span>" }
        [void]$sb.AppendLine("    <tr><td>$($r.EndTime.ToString('HH:mm:ss'))</td><td>$icon $($r.Name) (Zone $($r.Zone)) completed</td><td>$($r.Duration.ToString('mm\:ss'))</td></tr>")
    }

    [void]$sb.AppendLine("    <tr><td>$($deploymentEndTime.ToString('HH:mm:ss'))</td><td><span class='badge b-info'>END</span> All deployments completed</td><td>$($elapsed.ToString('mm\:ss')) total</td></tr>")
    [void]$sb.AppendLine("</tbody></table></div>")

    # ---- Footer ----
    [void]$sb.AppendLine(@"
<div class="footer">Azure Scale Test Report &bull; Generated by Deploy-ScaleTest.ps1 &bull; $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')</div>
</div></body></html>
"@)

    $sb.ToString() | Set-Content -Path $reportPath -Encoding UTF8
    Write-Success "Detailed report saved to: $reportPath"
    Write-Info "Report path: $reportPath"
} catch {
    Write-Failure "Report generation failed: $_"
    Write-Info "Continuing to cleanup phase..."
}

# ============================================================================
# Phase 6: Cleanup
# ============================================================================

if (-not $SkipCleanup) {
    Write-Phase "PHASE 6" "Deleting resource group '$rgName'..."
    $cleanupJob = Remove-AzResourceGroup -Name $rgName -Force -AsJob

    Write-Info "Cleanup initiated. Monitoring deletion progress..."
    $cleanupTimeout = 1800  # 30 minutes max for RG deletion
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
Write-Phase "DONE" "Scale test complete"
Write-Host "=" * 60 -ForegroundColor White

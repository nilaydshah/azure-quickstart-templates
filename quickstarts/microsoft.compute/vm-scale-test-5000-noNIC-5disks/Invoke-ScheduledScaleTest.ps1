<#
.SYNOPSIS
    Automated end-to-end scale test orchestrator. Monitors quota, launches 5K VM deployment,
    waits for stabilization, and performs full cleanup.

.DESCRIPTION
    Designed to run unattended via Windows Task Scheduler (twice daily).
    
    Phases:
    0. Quota monitoring — polls DDSv5 every 2 min until ≤ threshold (60 min timeout)
    1. Launch scale test — calls Deploy-ScaleTest-NoNIC-5disks.ps1
    2. Stabilization — 15 min wait (handled by deploy script)
    3. Cleanup — delete VMs (batch 500), disks (batch 1000 parallel), then RG

.PARAMETER SubscriptionId
    Azure subscription ID. Default: scalability subscription.

.PARAMETER Location
    Azure region. Default: EastUS2EUAP

.PARAMETER TotalVmCount
    Total VMs to deploy. Default: 4998

.PARAMETER QuotaThreshold
    Max DDSv5 cores in use before launching. Default: 200

.PARAMETER QuotaPollIntervalSec
    Seconds between quota checks. Default: 120

.PARAMETER QuotaTimeoutMin
    Max minutes to wait for quota. Default: 60

.PARAMETER DiskDeleteThrottleLimit
    Parallel throttle limit for disk deletion. Default: 50

.PARAMETER SkipQuotaCheck
    Skip quota monitoring and launch immediately.

.PARAMETER SkipCleanup
    Skip cleanup after deployment.

.EXAMPLE
    .\Invoke-ScheduledScaleTest.ps1
    Runs full automated cycle: monitor quota → deploy → stabilize → cleanup

.EXAMPLE
    .\Invoke-ScheduledScaleTest.ps1 -SkipQuotaCheck
    Launches immediately without waiting for quota headroom.
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId = "b883903d-216e-45b3-98b0-058819ec9224",
    [string]$Location = "EastUS2EUAP",
    [int]$TotalVmCount = 4998,
    [int]$BatchSize = 500,
    [int]$QuotaThreshold = 200,
    [int]$QuotaPollIntervalSec = 120,
    [int]$QuotaTimeoutMin = 60,
    [int]$DiskDeleteBatchSize = 1000,
    [int]$DiskDeleteThrottleLimit = 50,
    [switch]$SkipQuotaCheck,
    [switch]$SkipCleanup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogDir = Join-Path $ScriptDir "logs"
$DeployScript = Join-Path $ScriptDir "Deploy-ScaleTest-NoNIC-5disks.ps1"

# Ensure logs directory exists
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

$RunTimestamp = Get-Date -Format "yyyy-MM-dd-HHmmss"
$LogFile = Join-Path $LogDir "ScaleTest-$RunTimestamp.log"
$SummaryFile = Join-Path $LogDir "ScaleTest-$RunTimestamp-summary.json"

# ============================================================================
# Logging
# ============================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$ts] [$Level] $Message"
    Write-Host $line
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Write-LogPhase {
    param([string]$Phase, [string]$Message)
    Write-Log "[$Phase] $Message" -Level "PHASE"
}

# ============================================================================
# Summary tracking
# ============================================================================

$summary = @{
    RunTimestamp     = $RunTimestamp
    SubscriptionId  = $SubscriptionId
    Location        = $Location
    TotalVmCount    = $TotalVmCount
    Status          = "Started"
    QuotaWaitMin    = 0
    ResourceGroup   = ""
    DeployStart     = ""
    DeployEnd       = ""
    DeployDuration  = ""
    VmsCreated      = 0
    VmsRunning      = 0
    VmsFailed       = 0
    DisksCreated    = 0
    CleanupStart    = ""
    CleanupEnd      = ""
    ErrorMessage    = ""
}

function Save-Summary {
    $summary | ConvertTo-Json -Depth 3 | Out-File -FilePath $SummaryFile -Encoding utf8
}

# ============================================================================
# Phase 0: Quota Monitoring
# ============================================================================

Write-LogPhase "PHASE 0" "Starting automated scale test run"
Write-Log "Subscription: $SubscriptionId"
Write-Log "Location: $Location"
Write-Log "Target VMs: $TotalVmCount"
Write-Log "Log file: $LogFile"

# Set subscription context
try {
    Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
    Write-Log "Subscription context set successfully"
} catch {
    Write-Log "Failed to set subscription context: $_" -Level "ERROR"
    Write-Log "Attempting Connect-AzAccount..." -Level "WARN"
    try {
        Connect-AzAccount -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        Write-Log "Connected to Azure successfully"
    } catch {
        Write-Log "Cannot connect to Azure: $_" -Level "FATAL"
        $summary.Status = "Failed"
        $summary.ErrorMessage = "Azure authentication failed: $_"
        Save-Summary
        exit 1
    }
}

$requiredCores = $TotalVmCount * 2  # Standard_D2ds_v5 = 2 vCPUs each
Write-Log "Required vCPU cores: $requiredCores (for $TotalVmCount x Standard_D2ds_v5)"

if (-not $SkipQuotaCheck) {
    Write-LogPhase "PHASE 0" "Monitoring DDSv5 quota (threshold: ≤$QuotaThreshold cores in use, timeout: ${QuotaTimeoutMin}min)..."

    $quotaStart = Get-Date
    $quotaDeadline = $quotaStart.AddMinutes($QuotaTimeoutMin)
    $quotaReady = $false

    while ((Get-Date) -lt $quotaDeadline) {
        try {
            $usage = Get-AzVMUsage -Location $Location |
                Where-Object { $_.Name.Value -eq "standardDDSv5Family" }

            $currentUsage = $usage.CurrentValue
            $limit = $usage.Limit
            $available = $limit - $currentUsage

            Write-Log "DDSv5 quota: $currentUsage/$limit (available: $available, need: $requiredCores)"

            if ($currentUsage -le $QuotaThreshold) {
                $waitElapsed = [math]::Round(((Get-Date) - $quotaStart).TotalMinutes, 1)
                Write-Log "Quota is safe ($currentUsage ≤ $QuotaThreshold). Waited ${waitElapsed} minutes."
                $summary.QuotaWaitMin = $waitElapsed
                $quotaReady = $true
                break
            }

            if ($available -lt $requiredCores) {
                Write-Log "Insufficient total quota: $available available, $requiredCores required" -Level "WARN"
            }
        } catch {
            Write-Log "Quota check failed: $_" -Level "WARN"
        }

        $remainMin = [math]::Round(($quotaDeadline - (Get-Date)).TotalMinutes, 1)
        Write-Log "Quota not ready. Waiting ${QuotaPollIntervalSec}s... (${remainMin}min until timeout)"
        Start-Sleep -Seconds $QuotaPollIntervalSec
    }

    if (-not $quotaReady) {
        Write-Log "Quota timeout reached after ${QuotaTimeoutMin} minutes. Aborting run." -Level "ERROR"
        $summary.Status = "QuotaTimeout"
        $summary.ErrorMessage = "DDSv5 quota not available within ${QuotaTimeoutMin} minutes"
        Save-Summary
        exit 2
    }
} else {
    Write-Log "Quota check skipped (-SkipQuotaCheck)"
}

# ============================================================================
# Phase 1: Launch Scale Test
# ============================================================================

Write-LogPhase "PHASE 1" "Launching scale test deployment..."
$summary.DeployStart = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

try {
    # Call the deploy script — capture output via transcript
    $deployOutput = & $DeployScript `
        -SubscriptionId $SubscriptionId `
        -Location $Location `
        -TotalVmCount $TotalVmCount `
        -BatchSize $BatchSize `
        -SkipCleanup `
        2>&1

    # Log all output
    $deployOutput | ForEach-Object { $_ | Out-File -FilePath $LogFile -Append -Encoding utf8 }

    $summary.DeployEnd = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Write-Log "Deployment script completed"
} catch {
    Write-Log "Deployment script failed: $_" -Level "ERROR"
    $summary.Status = "DeployFailed"
    $summary.ErrorMessage = "Deploy script error: $_"
    $summary.DeployEnd = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    Save-Summary
    # Don't exit — try to identify the RG for cleanup
}

# ============================================================================
# Phase 2: Identify Resources & Capture Summary
# ============================================================================

Write-LogPhase "PHASE 2" "Identifying deployed resources..."

# Find the TDPR-RG created by this run
$tdprRGs = Get-AzResourceGroup | Where-Object {
    $_.ResourceGroupName -match "^TDPR-RG-" -and
    $_.Location -eq $Location.ToLower().Replace(" ", "")
} | Sort-Object { $_.Tags["CreatedDate"] } -Descending

if ($tdprRGs.Count -eq 0) {
    # Try broader search
    $tdprRGs = Get-AzResourceGroup | Where-Object {
        $_.ResourceGroupName -match "^TDPR-RG-"
    } | Sort-Object ResourceGroupName -Descending
}

if ($tdprRGs.Count -gt 0) {
    $rgName = $tdprRGs[0].ResourceGroupName
    $summary.ResourceGroup = $rgName
    Write-Log "Active resource group: $rgName"
} else {
    Write-Log "No TDPR-RG resource group found. Nothing to clean up." -Level "WARN"
    $summary.Status = "NoRGFound"
    $summary.ErrorMessage = "Could not find TDPR-RG resource group after deployment"
    Save-Summary
    exit 3
}

# Count resources
try {
    $resources = @(Get-AzResource -ResourceGroupName $rgName)
    $vmCount = @($resources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/virtualMachines" }).Count
    $diskCount = @($resources | Where-Object { $_.ResourceType -eq "Microsoft.Compute/disks" }).Count
    $nicCount = @($resources | Where-Object { $_.ResourceType -eq "Microsoft.Network/networkInterfaces" }).Count

    $summary.VmsCreated = $vmCount
    $summary.DisksCreated = $diskCount

    Write-Log "Resources — VMs: $vmCount, Disks: $diskCount, NICs: $nicCount"
} catch {
    Write-Log "Could not count resources: $_" -Level "WARN"
}

# Get VM status
try {
    $vms = @(Get-AzVM -ResourceGroupName $rgName -Status)
    $running = @($vms | Where-Object { $_.PowerState -eq "VM running" }).Count
    $failed = @($vms | Where-Object { $_.ProvisioningState -eq "Failed" }).Count

    $summary.VmsRunning = $running
    $summary.VmsFailed = $failed

    Write-Log "VM Status — Total: $($vms.Count), Running: $running, Failed: $failed"
} catch {
    Write-Log "Could not query VM status: $_" -Level "WARN"
}

# ============================================================================
# Phase 3: Cleanup
# ============================================================================

if ($SkipCleanup) {
    Write-Log "Cleanup skipped (-SkipCleanup). RG: $rgName"
    $summary.Status = "CompletedNoCleanup"
    Save-Summary
    exit 0
}

Write-LogPhase "PHASE 3" "Starting cleanup of $rgName..."
$summary.CleanupStart = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# --- Step 1: Delete VMs ---
Write-Log "Step 1: Deleting VMs in batches of $BatchSize..."

try {
    $allVMs = @(Get-AzVM -ResourceGroupName $rgName)
    $vmTotal = $allVMs.Count
    Write-Log "VMs to delete: $vmTotal"

    if ($vmTotal -gt 0) {
        $vmBatchCount = [math]::Ceiling($vmTotal / $BatchSize)
        for ($i = 0; $i -lt $vmBatchCount; $i++) {
            $batch = $allVMs | Select-Object -Skip ($i * $BatchSize) -First $BatchSize
            Write-Log "Deleting VM batch $($i+1)/$vmBatchCount ($($batch.Count) VMs)..."
            $batch | ForEach-Object {
                Remove-AzVM -ResourceGroupName $rgName -Name $_.Name -ForceDeletion $true -NoWait -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Log "All VM deletion requests sent. Waiting for completion..."
        Start-Sleep -Seconds 180

        # Poll until VMs are gone
        $maxVmWait = 30  # max 30 minutes
        $vmWaitStart = Get-Date
        do {
            $remaining = @(Get-AzVM -ResourceGroupName $rgName).Count
            Write-Log "Remaining VMs: $remaining"
            if ($remaining -eq 0) { break }
            if (((Get-Date) - $vmWaitStart).TotalMinutes -gt $maxVmWait) {
                Write-Log "VM deletion timeout after ${maxVmWait}min. $remaining VMs remain." -Level "WARN"
                break
            }
            Start-Sleep -Seconds 120
        } while ($true)
    }

    Write-Log "VM deletion complete"
} catch {
    Write-Log "VM deletion error: $_" -Level "ERROR"
}

# --- Step 2: Delete Disks ---
Write-Log "Step 2: Deleting disks in batches of $DiskDeleteBatchSize..."

try {
    $allDisks = @(Get-AzDisk -ResourceGroupName $rgName)
    $diskTotal = $allDisks.Count
    Write-Log "Disks to delete: $diskTotal"

    if ($diskTotal -gt 0) {
        $diskBatchCount = [math]::Ceiling($diskTotal / $DiskDeleteBatchSize)

        for ($b = 1; $b -le $diskBatchCount; $b++) {
            $batch = $allDisks | Select-Object -Skip (($b - 1) * $DiskDeleteBatchSize) -First $DiskDeleteBatchSize
            $batchCount = $batch.Count
            Write-Log "Deleting disk batch $b/$diskBatchCount ($batchCount disks)..."

            $batch | ForEach-Object -Parallel {
                $rg = $using:rgName
                Remove-AzDisk -ResourceGroupName $rg -DiskName $_.Name -Force -ErrorAction SilentlyContinue | Out-Null
            } -ThrottleLimit $DiskDeleteThrottleLimit

            Write-Log "Disk batch $b/$diskBatchCount complete"
        }

        # Check for stragglers
        $remainingDisks = @(Get-AzDisk -ResourceGroupName $rgName).Count
        if ($remainingDisks -gt 0) {
            Write-Log "$remainingDisks disks remain after initial pass. Running cleanup pass..."
            $stragglers = @(Get-AzDisk -ResourceGroupName $rgName)
            $stragglers | ForEach-Object -Parallel {
                $rg = $using:rgName
                Remove-AzDisk -ResourceGroupName $rg -DiskName $_.Name -Force -ErrorAction SilentlyContinue | Out-Null
            } -ThrottleLimit $DiskDeleteThrottleLimit
        }
    }

    Write-Log "Disk deletion complete"
} catch {
    Write-Log "Disk deletion error: $_" -Level "ERROR"
}

# --- Step 3: Delete Resource Group ---
Write-Log "Step 3: Deleting resource group $rgName..."

try {
    Remove-AzResourceGroup -Name $rgName -Force -ErrorAction Stop
    Write-Log "Resource group $rgName deleted successfully"
} catch {
    Write-Log "RG deletion error (may still be deleting): $_" -Level "WARN"
}

$summary.CleanupEnd = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")

# ============================================================================
# Final Summary
# ============================================================================

$summary.Status = "Completed"
$deployStart = if ($summary.DeployStart) { [datetime]::Parse($summary.DeployStart) } else { $null }
$deployEnd = if ($summary.DeployEnd) { [datetime]::Parse($summary.DeployEnd) } else { $null }
if ($deployStart -and $deployEnd) {
    $summary.DeployDuration = "{0:mm\:ss}" -f ($deployEnd - $deployStart)
}

Save-Summary

Write-Log "=" * 60
Write-LogPhase "DONE" "Automated scale test run complete"
Write-Log "Resource Group:  $($summary.ResourceGroup)"
Write-Log "VMs Created:     $($summary.VmsCreated)"
Write-Log "VMs Running:     $($summary.VmsRunning)"
Write-Log "VMs Failed:      $($summary.VmsFailed)"
Write-Log "Disks Created:   $($summary.DisksCreated)"
Write-Log "Deploy Duration: $($summary.DeployDuration)"
Write-Log "Quota Wait:      $($summary.QuotaWaitMin) min"
Write-Log "Summary:         $SummaryFile"
Write-Log "=" * 60

<#
.SYNOPSIS
    Registers (or unregisters) the Scale Test 5K VMs scheduled task in Windows Task Scheduler.

.DESCRIPTION
    Creates a Windows Scheduled Task that runs Invoke-ScheduledScaleTest.ps1 twice daily.
    The task monitors Azure DDSv5 quota, launches a 5K VM scale test when safe, and cleans up.

.PARAMETER Action
    'Register' to create the task, 'Unregister' to remove it. Default: Register

.PARAMETER TaskName
    Name of the scheduled task. Default: ScaleTest-5K-VMs

.PARAMETER RunTimes
    Array of daily run times (24h format). Default: @("06:00", "18:00")

.PARAMETER MaxRuntimeHours
    Maximum execution time before the task is killed. Default: 6

.EXAMPLE
    .\Register-ScaleTestTask.ps1
    Registers the task to run at 06:00 and 18:00 daily.

.EXAMPLE
    .\Register-ScaleTestTask.ps1 -RunTimes @("08:00", "20:00")
    Registers with custom run times.

.EXAMPLE
    .\Register-ScaleTestTask.ps1 -Action Unregister
    Removes the scheduled task.
#>

[CmdletBinding()]
param(
    [ValidateSet("Register", "Unregister")]
    [string]$Action = "Register",

    [string]$TaskName = "ScaleTest-5K-VMs",

    [string[]]$RunTimes = @("06:00", "18:00"),

    [int]$MaxRuntimeHours = 6
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OrchestratorScript = Join-Path $ScriptDir "Invoke-ScheduledScaleTest.ps1"

# ============================================================================
# Unregister
# ============================================================================

if ($Action -eq "Unregister") {
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "[SUCCESS] Scheduled task '$TaskName' removed." -ForegroundColor Green
    } else {
        Write-Host "[INFO] Scheduled task '$TaskName' does not exist." -ForegroundColor Yellow
    }
    return
}

# ============================================================================
# Register
# ============================================================================

if (-not (Test-Path $OrchestratorScript)) {
    Write-Host "[ERROR] Orchestrator script not found: $OrchestratorScript" -ForegroundColor Red
    Write-Host "        Ensure Invoke-ScheduledScaleTest.ps1 exists in the same directory." -ForegroundColor Red
    exit 1
}

# Find pwsh.exe (PowerShell 7+)
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) {
    $pwshPath = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (-not (Test-Path $pwshPath)) {
        Write-Host "[ERROR] pwsh.exe (PowerShell 7+) not found. Install from https://aka.ms/powershell" -ForegroundColor Red
        exit 1
    }
}

Write-Host "Registering scheduled task: $TaskName" -ForegroundColor Cyan
Write-Host "  Orchestrator: $OrchestratorScript" -ForegroundColor Gray
Write-Host "  PowerShell:   $pwshPath" -ForegroundColor Gray
Write-Host "  Schedule:     Daily at $($RunTimes -join ', ')" -ForegroundColor Gray
Write-Host "  Max runtime:  $MaxRuntimeHours hours" -ForegroundColor Gray
Write-Host ""

# Build triggers — one trigger per run time
$triggers = @()
foreach ($time in $RunTimes) {
    $triggers += New-ScheduledTaskTrigger -Daily -At $time
}

# Action — run pwsh with the orchestrator script
$taskAction = New-ScheduledTaskAction `
    -Execute $pwshPath `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$OrchestratorScript`"" `
    -WorkingDirectory $ScriptDir

# Settings
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Hours $MaxRuntimeHours) `
    -MultipleInstances IgnoreNew `
    -RestartCount 1 `
    -RestartInterval (New-TimeSpan -Minutes 5)

# Principal — current user, highest privileges
$principal = New-ScheduledTaskPrincipal `
    -UserId ([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) `
    -LogonType Interactive `
    -RunLevel Highest

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing task '$TaskName'..." -ForegroundColor Yellow
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

# Register
$task = Register-ScheduledTask `
    -TaskName $TaskName `
    -Trigger $triggers `
    -Action $taskAction `
    -Settings $settings `
    -Principal $principal `
    -Description "Automated Azure 5K VM Scale Test — monitors DDSv5 quota, deploys VMs, collects results, and cleans up."

Write-Host ""
Write-Host "=" * 60 -ForegroundColor Green
Write-Host "[SUCCESS] Scheduled task '$TaskName' registered!" -ForegroundColor Green
Write-Host "=" * 60 -ForegroundColor Green
Write-Host ""
Write-Host "  Task Name:    $TaskName"
Write-Host "  Schedule:     Daily at $($RunTimes -join ', ')"
Write-Host "  Max Runtime:  $MaxRuntimeHours hours"
Write-Host "  Status:       $($task.State)"
Write-Host ""
Write-Host "Useful commands:" -ForegroundColor Cyan
Write-Host "  Get-ScheduledTask -TaskName '$TaskName'              # Check status"
Write-Host "  Start-ScheduledTask -TaskName '$TaskName'            # Run now"
Write-Host "  Stop-ScheduledTask -TaskName '$TaskName'             # Stop running"
Write-Host "  .\Register-ScaleTestTask.ps1 -Action Unregister      # Remove task"

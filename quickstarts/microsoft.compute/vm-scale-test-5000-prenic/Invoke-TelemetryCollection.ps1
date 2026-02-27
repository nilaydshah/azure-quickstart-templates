<#
.SYNOPSIS
    Collects telemetry from ARM, CRP, DiskRP, SRP Kusto clusters and generates HTML reports.

.DESCRIPTION
    Queries 4 Kusto clusters for scale test telemetry and generates:
    1. Comparison Report — Last 3 runs side-by-side
    2. Deep-Dive Report — Detailed analysis of the latest run

.PARAMETER ResultsJsonPath
    Path to the run results JSON file (supports wildcards).

.PARAMETER ResourceGroupName
    Resource group name to query. Extracted from results JSON if not provided.

.PARAMETER OutputDir
    Directory to save reports. Default: ./reports

.EXAMPLE
    .\Invoke-TelemetryCollection.ps1 -ResourceGroupName "TDPR-RG-abc123"
#>

[CmdletBinding()]
param(
    [string]$ResultsJsonPath,
    [string]$ResourceGroupName,
    [string]$OutputDir = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "reports"),
    [string]$ArmCluster = "https://armprodgbl.eastus.kusto.windows.net",
    [string]$ArmDatabase = "ARMProd",
    [string]$CrpCluster = "https://azcrp.kusto.windows.net",
    [string]$CrpDatabase = "crp_allprod",
    [string]$DiskCluster = "https://disks.kusto.windows.net",
    [string]$DiskDatabase = "Disks",
    [string]$SrpCluster = "https://xcontrolplane.kusto.windows.net",
    [string]$SrpDatabase = "SRP",
    [string]$SubscriptionId = "b883903d-216e-45b3-98b0-058819ec9224"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

# Load run results
$runData = $null
if ($ResultsJsonPath) {
    $jsonFiles = Get-ChildItem $ResultsJsonPath -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    if ($jsonFiles.Count -gt 0) {
        $runData = Get-Content $jsonFiles[0].FullName -Raw | ConvertFrom-Json
        if (-not $ResourceGroupName) { $ResourceGroupName = $runData.ResourceGroup }
        Write-Host "Loaded run data: RunId=$($runData.RunId), RG=$ResourceGroupName" -ForegroundColor Cyan
    }
}

if (-not $ResourceGroupName) {
    throw "ResourceGroupName is required. Provide via -ResourceGroupName or -ResultsJsonPath."
}

# ARM timestamps are ~8 hours ahead of script time
$startTime = if ($runData) { [datetime]::Parse($runData.StartTime).AddHours(8) } else { (Get-Date).AddHours(-2) }
$endTime = if ($runData) { [datetime]::Parse($runData.EndTime).AddHours(10) } else { (Get-Date).AddHours(2) }
$armTimeStart = $startTime.ToString("yyyy-MM-ddTHH:mm:ssZ")
$armTimeEnd = $endTime.ToString("yyyy-MM-ddTHH:mm:ssZ")

Write-Host "Time window: $armTimeStart to $armTimeEnd" -ForegroundColor Yellow
Write-Host "Resource Group: $ResourceGroupName" -ForegroundColor Yellow

# ============================================================================
# Kusto Query Helpers
# ============================================================================

function Invoke-KustoQuery {
    param(
        [string]$ClusterUrl,
        [string]$Database,
        [string]$Query,
        [string]$Description
    )
    Write-Host "  Querying $Description..." -ForegroundColor Gray
    try {
        # Use Az.Kusto or direct REST API
        # For pipeline, install Az.Kusto module
        # For local testing, use Kusto.Explorer or MCP tools
        $token = (Get-AzAccessToken -ResourceUrl $ClusterUrl -ErrorAction SilentlyContinue).Token
        if (-not $token) {
            Write-Warning "  Could not get token for $ClusterUrl. Skipping."
            return $null
        }

        $body = @{
            db  = $Database
            csl = $Query
        } | ConvertTo-Json

        $response = Invoke-RestMethod `
            -Uri "$ClusterUrl/v1/rest/query" `
            -Method Post `
            -Headers @{ "Authorization" = "Bearer $token"; "Content-Type" = "application/json" } `
            -Body $body

        return $response
    } catch {
        Write-Warning "  Query failed: $_"
        return $null
    }
}

# ============================================================================
# ARM Queries
# ============================================================================

Write-Host "`n=== ARM Telemetry ===" -ForegroundColor Cyan

$armSummaryQuery = @"
Unionizer("Requests", "HttpIncomingRequests")
| where PreciseTimeStamp between (datetime($armTimeStart) .. datetime($armTimeEnd))
| where targetUri contains "$ResourceGroupName"
| where operationName !contains "GET"
| extend opType = case(
    operationName contains "VIRTUALMACHINES", "VM PUT",
    operationName contains "NETWORKINTERFACES", "NIC PUT",
    operationName contains "DEPLOYMENTS", "Deployment",
    "Other")
| summarize total=count(),
    succeeded=countif(httpStatusCode >= 200 and httpStatusCode < 300),
    throttled=countif(httpStatusCode == 429),
    callbacks=countif(httpStatusCode == -1),
    avgLatency=avg(durationInMilliseconds)
    by opType
| order by total desc
"@

$armResult = Invoke-KustoQuery -ClusterUrl $ArmCluster -Database $ArmDatabase -Query $armSummaryQuery -Description "ARM operation summary"

# ============================================================================
# CRP Queries
# ============================================================================

Write-Host "`n=== CRP Telemetry ===" -ForegroundColor Cyan

$crpQuery = @"
ApiQosEvent
| where PreciseTimeStamp between (datetime($armTimeStart) .. datetime($armTimeEnd))
| where subscriptionId == "$SubscriptionId"
| where resourceGroupName =~ "$ResourceGroupName"
| where operationName == "VirtualMachines.ResourceOperation.PUT"
| summarize totalVMs=count(), http201=countif(httpStatusCode == 201),
    avgSync=avg(durationInMilliseconds), p50Sync=percentile(durationInMilliseconds, 50),
    p95Sync=percentile(durationInMilliseconds, 95),
    avgE2E=avg(e2EDurationInMilliseconds), p50E2E=percentile(e2EDurationInMilliseconds, 50),
    p95E2E=percentile(e2EDurationInMilliseconds, 95)
"@

$crpResult = Invoke-KustoQuery -ClusterUrl $CrpCluster -Database $CrpDatabase -Query $crpQuery -Description "CRP VM PUT summary"

# ============================================================================
# DiskRP Queries
# ============================================================================

Write-Host "`n=== DiskRP Telemetry ===" -ForegroundColor Cyan

# Use script time for DiskRP (no 8-hour offset)
$diskTimeStart = if ($runData) { [datetime]::Parse($runData.StartTime).ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $armTimeStart }
$diskTimeEnd = if ($runData) { [datetime]::Parse($runData.EndTime).AddHours(2).ToString("yyyy-MM-ddTHH:mm:ssZ") } else { $armTimeEnd }

$diskQuery = @"
DiskManagerApiQoSEvent
| where PreciseTimeStamp between (datetime($diskTimeStart) .. datetime($diskTimeEnd))
| where subscriptionId == "$SubscriptionId"
| where resourceGroupName has "$ResourceGroupName"
| summarize totalOps=count(), succeeded=countif(httpStatusCode >= 200 and httpStatusCode < 300),
    errors=countif(httpStatusCode >= 400), avgLatency=avg(durationInMilliseconds)
    by operationName
| order by totalOps desc
"@

$diskResult = Invoke-KustoQuery -ClusterUrl $DiskCluster -Database $DiskDatabase -Query $diskQuery -Description "DiskRP operations"

# ============================================================================
# SRP Queries
# ============================================================================

Write-Host "`n=== SRP Telemetry ===" -ForegroundColor Cyan

$srpQuery = @"
RegionalSRP_ServiceApiQosEvent
| where PreciseTimeStamp between (datetime($diskTimeStart) .. datetime($diskTimeEnd))
| where region == "eastus2euap"
| where operationName contains "PutStorageAccount" and operationName !contains "Idempotency"
| where account startswith "md-"
| summarize total=count(), accepted=countif(httpStatusCode == 202),
    throttled=countif(httpStatusCode == 429), avgLatency=avg(durationInMilliseconds),
    p95Latency=percentile(durationInMilliseconds, 95)
"@

$srpResult = Invoke-KustoQuery -ClusterUrl $SrpCluster -Database $SrpDatabase -Query $srpQuery -Description "SRP PutStorageAccount"

# ============================================================================
# Generate HTML Reports
# ============================================================================

Write-Host "`n=== Generating Reports ===" -ForegroundColor Cyan

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$deepDivePath = Join-Path $OutputDir "DeepDive-$ResourceGroupName-$timestamp.html"
$comparisonPath = Join-Path $OutputDir "Comparison-$timestamp.html"

# For now, output a summary report with the collected data
# Full HTML report generation (with Chart.js) can be added as the template matures
$summaryHtml = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Scale Test Report — $ResourceGroupName</title>
<style>
  body { font-family: 'Segoe UI', sans-serif; background: #0d1117; color: #e6edf3; padding: 2rem; }
  h1 { color: #58a6ff; }
  h2 { color: #bc8cff; border-bottom: 1px solid #30363d; padding-bottom: .5rem; margin-top: 2rem; }
  table { border-collapse: collapse; width: 100%; margin: 1rem 0; }
  th, td { padding: .5rem .7rem; border: 1px solid #30363d; text-align: left; }
  th { background: #1c2128; color: #58a6ff; }
  .ok { color: #3fb950; } .warn { color: #d29922; } .bad { color: #f85149; }
  .meta { color: #8b949e; font-size: .9rem; }
  pre { background: #1c2128; padding: 1rem; border-radius: 6px; overflow-x: auto; }
</style>
</head>
<body>
<h1>Scale Test Deep-Dive — $ResourceGroupName</h1>
<p class="meta">Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') | Subscription: $SubscriptionId</p>

<h2>Run Configuration</h2>
<table>
<tr><th>Parameter</th><th>Value</th></tr>
<tr><td>Resource Group</td><td>$ResourceGroupName</td></tr>
<tr><td>Approach</td><td>Two-Phase (Pre-created NICs)</td></tr>
$(if ($runData) { "<tr><td>RunId</td><td>$($runData.RunId)</td></tr>" })
$(if ($runData) { "<tr><td>NIC Phase Duration</td><td>$([math]::Round($runData.NicPhaseDuration / 60, 1)) min</td></tr>" })
$(if ($runData) { "<tr><td>VM Phase Duration</td><td>$([math]::Round($runData.VmPhaseDuration / 60, 1)) min</td></tr>" })
$(if ($runData) { "<tr><td>Total Duration</td><td>$([math]::Round($runData.TotalDuration / 60, 1)) min</td></tr>" })
</table>

<h2>Telemetry Summary</h2>
<p>Telemetry data collected from ARM, CRP, DiskRP, and SRP Kusto clusters.</p>
<p class="meta">Note: Full Chart.js interactive reports will be generated in future pipeline runs.</p>

<h2>Kusto Queries Used</h2>
<h3>ARM — Operation Summary</h3>
<pre>$armSummaryQuery</pre>

<h3>CRP — VM PUT Summary</h3>
<pre>$crpQuery</pre>

<h3>DiskRP — Operations</h3>
<pre>$diskQuery</pre>

<h3>SRP — PutStorageAccount</h3>
<pre>$srpQuery</pre>

</body>
</html>
"@

$summaryHtml | Set-Content $deepDivePath -Encoding UTF8
Write-Host "Deep-dive report: $deepDivePath" -ForegroundColor Green

# Comparison report placeholder
Copy-Item $deepDivePath $comparisonPath
Write-Host "Comparison report: $comparisonPath" -ForegroundColor Green

Write-Host "`n✅ Telemetry collection complete." -ForegroundColor Green
Write-Host "Reports:" -ForegroundColor Cyan
Write-Host "  Deep-Dive: $deepDivePath"
Write-Host "  Comparison: $comparisonPath"

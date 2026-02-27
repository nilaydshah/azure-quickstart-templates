# Cross-Layer Action Items: VM Scale Test (TDPR-RG-sdkhgv11)

**Scale Test Deployment Start:** 2026-02-20 01:35 UTC (Serial Copy Mode)  
**Report Generated:** 2026-02-20  
**Scale Test:** 5,000 VM deployment in EastUS2EUAP  
**Result:** 3,849 VMs succeeded (99.8% of deployed), 7 failed (OSProvisioningTimedOut)

---

## Priority 1: Critical (Blocks SLA Target)

### AI-1: Reduce CRP VM E2E Latency (P50: 9.1s → Target: 5s)
- **Layer:** CRP + OS Provisioning
- **Current:** P50=9.1s, P90=23.8s, P99=39.3s
- **Root Cause:** 89.3% of E2E time is OS provisioning (guest boot + Azure VM agent startup). CRP sync processing is only 466ms.
- **Actions:**
  1. Investigate faster boot images (pre-provisioned guest agent, minimal boot)
  2. Profile Ubuntu 22.04 LTS Gen2 boot sequence to identify slow stages
  3. Consider pre-provisioned OS disk images with agent already running
  4. Evaluate if cloud-init scripts can be deferred post-provisioning
- **Owner:** CRP / Guest OS team
- **SLA Impact:** Reducing P50 from 9.1s to 5s would improve overall scale test completion time by ~45%

### AI-2: Address 1,144 Missing VMs (5,000 target → 3,856 deployed)
- **Layer:** ARM / Template Processing
- **Current:** Only 3,856 out of 5,000 VMs were deployed (77.1%)
- **Root Cause:** ARM template copy loops with 250 VMs per batch; some batches partially failed due to throttling and resource contention
- **Actions:**
  1. Analyze per-batch deployment operation logs to identify exact failure reasons
  2. Implement retry logic for failed batch VMs
  3. Consider reducing batch size from 250 to 100 VMs per batch (more batches, less contention)
  4. Stagger batch submissions by 5-10 seconds to avoid thundering herd
- **Owner:** Scale Test Script / ARM team

---

## Priority 2: High (Impacts Reliability)

### AI-3: Mitigate ARM Throttling (29 HTTP 429s)
- **Layer:** ARM
- **Current:** 29 requests throttled at 01:45 UTC during peak burst
- **Root Cause:** 20 ARM template deployments submitted simultaneously, each creating 250 VMs
- **Actions:**
  1. Stagger batch submissions: add 5-second delay between batch launches
  2. Request ARM write limit increase for this subscription
  3. Implement exponential backoff retry in orchestration script
- **Owner:** Scale Test Script
- **Effort:** Low (script change)

### AI-4: Investigate XStore FetchInternalProperties Failures (3.5%)
- **Layer:** DiskRP → XStore
- **Current:** 96.54% success rate (12,208 failures out of 353,157 calls)
- **Root Cause:** Unknown — could be timeouts under load or race conditions during concurrent operations
- **Actions:**
  1. Query `DiskRPExternalComponentQoSEvent` to correlate failures with specific storage accounts
  2. Check if failures are concentrated on specific pseudo subscriptions
  3. Determine if failures are 404s (expected during cleanup) vs timeouts
  4. If timeouts: engage XStore team with correlation IDs for investigation
- **Owner:** DiskRP / XStore team

### AI-5: Investigate XStore DeleteCorLink High Latency (P99: 1,050ms)
- **Layer:** DiskRP → XStore
- **Current:** 95.3% success rate, P99=1,050ms, Max=30,176ms
- **Root Cause:** Cleanup-path operation; at scale (197K calls), XStore CoR link deletion becomes slow
- **Actions:**
  1. Determine if this impacts RG deletion time (currently 30-60 minutes for ~20K resources)
  2. Evaluate batching/parallelism improvements in DiskRP cleanup path
  3. If blocking: engage XStore team for optimization
- **Owner:** DiskRP team
- **Impact:** Cleanup speed only, not VM creation

---

## Priority 3: Medium (Optimization)

### AI-6: Reduce ARM Processing Overhead (~500ms per request)
- **Layer:** ARM
- **Current:** ARM adds ~512ms overhead (ARM P50: 978ms vs CRP P50: 466ms)
- **Root Cause:** Authentication, authorization, routing, template processing baseline cost
- **Actions:**
  1. Evaluate if ARM template can be pre-validated to reduce per-request validation time
  2. Consider using direct CRP API calls instead of ARM for creation (bypasses ARM overhead)
  3. Profile ARM routing path for EastUS2EUAP to check for region-specific latency
- **Owner:** ARM team
- **Impact:** Would save ~500ms per VM creation, ~2.5 million ms total for 5K VMs

### AI-7: Optimize DiskRP Hydrator and ARM Registration Blocks
- **Layer:** DiskRP Internal Pipeline
- **Current:**
  - Hydrator: avg=120.9ms, P99=598ms, max=48,503ms
  - ArmRegistration: avg=104.6ms, P99=609ms, max=47,037ms
- **Root Cause:** These are the two slowest pipeline stages in disk creation
- **Actions:**
  1. Profile Hydrator block to understand what takes 120ms avg (blob copy? metadata setup?)
  2. Check if ARM Registration can be batched for multiple disks on same VM
  3. Investigate 48s/47s max outliers — are these timeout/retry scenarios?
- **Owner:** DiskRP team

### AI-8: Automate Scale Test Scheduling
- **Layer:** Infrastructure / Tooling
- **Actions:**
  1. Set up scheduled runs (daily or weekly) using Windows Task Scheduler or Azure DevOps pipeline
  2. Integrate Kusto queries into report generation (auto-query after each run)
  3. Build trend tracking — store per-run metrics in a local database
  4. Create comparison reports showing improvement/regression across runs
  5. Set up alerting for regressions (e.g., success rate drops below 95%)
- **Owner:** Scale Test Owner

---

## Per-Layer SLA Targets

| Layer | Metric | Current | Target | Gap |
|-------|--------|---------|--------|-----|
| ARM | VM PUT Success Rate | 99.3% | 99.9% | -0.6% |
| ARM | VM PUT P50 Latency | 978ms | 500ms | -478ms |
| CRP | VM PUT Sync P50 | 466ms | 300ms | -166ms |
| CRP | VM PUT E2E P50 | 9.1s | 5s | -4.1s |
| CRP | VM PUT E2E P99 | 39.3s | 15s | -24.3s |
| DiskRP | API Success Rate | 100% | 100% | ✅ Met |
| DiskRP | AllocateDisks P99 | 31ms | 50ms | ✅ Met |
| XStore | FetchInternalProps Success | 96.5% | 99.9% | -3.4% |
| XStore | DeleteCorLink P99 | 1,050ms | 200ms | -850ms |
| Overall | VM Deployment Rate | 77.1% | 99% | -21.9% |
| Overall | VM Success (of deployed) | 99.8% | 99.9% | -0.1% |

---

## Kusto Queries for Monitoring

### ARM Layer
```kql
// ARM VM PUT success rate and latency
Unionizer("Requests", "HttpIncomingRequests")
| where PreciseTimeStamp > ago(1d)
| where targetUri contains "<RG_NAME>"
| where operationName == "PUT/SUBSCRIPTIONS/RESOURCEGROUPS/PROVIDERS/MICROSOFT.COMPUTE/VIRTUALMACHINES/"
| where httpStatusCode > 0
| summarize Count=count(), Success=countif(httpStatusCode<400), Throttled=countif(httpStatusCode==429),
    P50=percentile(durationInMilliseconds,50), P99=percentile(durationInMilliseconds,99)
```

### CRP Layer
```kql
// CRP VM creation E2E latency
ApiQosEvent
| where PreciseTimeStamp > ago(1d)
| where subscriptionId == "<SUB_ID>" and resourceGroupName =~ "<RG_NAME>"
| where operationName == "VirtualMachines.ResourceOperation.PUT"
| summarize Count=count(), P50Sync=percentile(durationInMilliseconds,50),
    P50E2E=percentile(e2EDurationInMilliseconds,50), P99E2E=percentile(e2EDurationInMilliseconds,99)
```

### DiskRP Layer
```kql
// DiskRP success rate and latency
DiskManagerApiQoSEvent
| where PreciseTimeStamp > ago(1d)
| where subscriptionId == "<SUB_ID>" and resourceGroupName =~ "<RG_NAME>"
| summarize Count=count(), SuccessRate=round(100.0*countif(httpStatusCode<300)/count(),2),
    P50=percentile(durationInMilliseconds,50), P99=percentile(durationInMilliseconds,99)
    by operationName
```

### DiskRP → XStore
```kql
// XStore external calls from DiskRP
DiskRPExternalComponentQoSEvent
| where PreciseTimeStamp > ago(1d)
| where subscriptionId == "<SUB_ID>"
| where componentName in ("XStore","XStoreBlob")
| summarize Count=count(), SuccessRate=round(100.0*countif(operationResult=="Success")/count(),2),
    P50=percentile(durationInMs,50), P99=percentile(durationInMs,99)
    by componentName, operationName
```

---

## Data Sources

| Cluster | Database | Key Tables |
|---------|----------|------------|
| `armprodgbl.eastus.kusto.windows.net` | ARMProd | `Unionizer("Requests","HttpIncomingRequests")`, `HttpOutgoingRequests` |
| `azcrp.kusto.windows.net` | crp_allprod | `ApiQosEvent` |
| `disks.kusto.windows.net` | Disks | `DiskManagerApiQoSEvent`, `DiskRPExternalComponentQoSEvent`, `DiskRPResourceLifecycleEvent` |
| XStore (via DiskRP) | Disks | `DiskRPExternalComponentQoSEvent` where componentName="XStore" |

**Note:** XStore direct access requires pseudo subscription IDs from `DiskRPResourceLifecycleEvent.pseudosubscriptionId`. Customer subscription is not used internally for storage allocation.

# BlackBox performance collection

BlackBox records Windows performance counters in the background so you can investigate slowdowns after they happen. It captures CPU, process memory, disk, network, and GPU activity every **15 seconds**, providing a timeline to compare with the time an issue was reported.

## What it does

- Creates or updates a Performance Monitor Data Collector Set named **BlackBox**.
- Creates or updates **Start BlackBox**, a scheduled task that starts the saved collector at boot as SYSTEM, without requiring sign-in.
- Starts collection immediately after installation and verifies running status.
- Allows the startup task to run on batteries and retries failed launches three times at one-minute intervals.
- Validates counter availability and warns when unsupported counters are skipped.

The startup task is not a continuous watchdog: it does not restart collection if collection stops later in the session. BlackBox collects diagnostic data; it does not send alerts or automatically identify a root cause.

## Install or update

Open **Windows PowerShell 5.1** (`powershell.exe`) with **Run as administrator**, then change to the directory containing the script. PowerShell 7 is not supported by this script.

```powershell
.\Configure-BlackBox.ps1 -Action Install
```

Wait for the `SUCCESS` message confirming that collection is running and the startup task is registered. Running Install again updates the same objects. An existing running collector is stopped and restarted during the update.

For detailed validation notices:

```powershell
.\Configure-BlackBox.ps1 -Action Install -Verbose
```

Check the collector and startup task:

```powershell
logman.exe query BlackBox
Get-ScheduledTask -TaskName 'Start BlackBox' -TaskPath '\'
Get-ScheduledTaskInfo -TaskName 'Start BlackBox' -TaskPath '\'
```

The task launches `logman.exe` and exits. Its state can be `Ready` while collection continues; use the collector status to check collection.

## Remove

From an elevated Windows PowerShell 5.1 prompt in the script directory:

```powershell
.\Configure-BlackBox.ps1 -Action Remove
```

Removal unregisters **Start BlackBox**, stops **BlackBox** if running, and deletes its collector configuration. **All collected log files and directories are preserved.** Differently named tasks and collectors remain untouched.

Removal is safe to repeat when either resource is already absent. If one cleanup step fails, the script still attempts the other and reports incomplete removal. Removal does not validate counters.

Both actions return exit code `0` on success or `1` on operational failure. Failed installation can leave partial changes; completed steps are reported with the error.

## Logs and configuration

| Setting | Current value |
| --- | --- |
| Sample interval | 15 seconds |
| Log root | `%SystemDrive%\PerfLogs\Admin`, usually `C:\PerfLogs\Admin` |
| Segment size | 300 MB per segment |
| Filename prefix | Computer name followed by `_` |
| Filename pattern | `dddtt` |
| Existing-file behavior | Overwrite enabled |

**300 MB is a segment limit, not a total disk usage limit.** The script adds no age-based or total-size cleanup. Files with matching names can be overwritten under the retained filename settings. Preserve relevant logs promptly after an incident. Use the collector properties in Performance Monitor to locate its actual output directory and files.

Edit `$counters`, `$sampleInterval`, `$segmentMaxSize`, or `$rootPath` in the configuration section near the top of the script, then rerun Install. Shorter intervals and more instances increase data volume and collection overhead.

Unavailable counters are skipped with warnings. If none are available, setup stops before changing existing resources. Validation checks counter catalog metadata rather than live samples, so an invalid sample does not exclude an installed counter. Wildcard paths remain configured even without active instances; explicit instances such as `C:` must exist at setup. Counter names must match the target Windows language. GPU and QoS counters depend on installed providers.

Expected PLA ignored-property notices for `TaskArguments` and `PerformanceCounterDataCollector[1]/LogAppend` appear only with `-Verbose`. Other warnings remain visible, and validation errors stop installation.

## Current counters and how they help

These are the 16 configured paths. The installed set may contain fewer if counters are unavailable. `(*)` collects matching instances so you can compare individual processes, CPUs, adapters, or GPU engines.

| Counter | Diagnostic use |
| --- | --- |
| `\Process(*)\% Privileged Time` | Kernel-mode CPU time attributed to each process. Helps distinguish kernel-related work from application computation during high CPU use. |
| `\Process(*)\% Processor Time` | CPU consumption per process. Identifies busy applications during a slowdown. A process using multiple logical processors can exceed 100%. |
| `\Processor Information(*)\% Processor Time` | CPU busy time by processor instance. Reveals broad saturation or one busy logical processor hidden by a lower overall average. |
| `\Processor Information(*)\% of Maximum Frequency` | Reported frequency relative to maximum. Compare with CPU demand when investigating power management or frequency limits; a low value alone does not prove thermal throttling. |
| `\Memory\Available MBytes` | Physical memory available for use. Sustained low availability suggests memory pressure; compare with process memory trends. |
| `\LogicalDisk(C:)\Current Disk Queue Length` | Outstanding I/O on `C:` at the sample time. A sustained queue alongside rising latency can indicate storage contention. |
| `\LogicalDisk(C:)\Avg. Disk sec/Transfer` | Average I/O completion time on `C:` in seconds. Multiply by 1,000 for milliseconds; rising values during an incident point toward storage delays. |
| `\Network Interface(*)\Bytes Total/sec` | Combined receive and send throughput by adapter. Helps correlate transfers and traffic bursts with a slowdown. |
| `\Network Interface(*)\Current Bandwidth` | Adapter-reported bandwidth in bits per second. Provides context for throughput; it does not measure end-to-end Internet or application bandwidth. |
| `\Processor(*)\% DPC Time` | CPU time servicing deferred procedure calls. Sustained increases can direct investigation toward driver or device activity. |
| `\Processor(*)\% Interrupt Time` | CPU time handling hardware interrupts. Helps identify heavy interrupt activity warranting driver or hardware investigation. |
| `\Process(*)\ID Process` | PID for each process counter instance. Correlates CPU and memory readings with the correct process when names repeat. |
| `\Process(*)\Private Bytes` | Private committed memory per process. Continued growth under comparable workload can suggest a leak; this is not resident physical RAM. |
| `\Process(*)\Virtual Bytes` | Virtual address space used by each process. Helps investigate address-space growth or exhaustion; this is not physical RAM usage. |
| `\GPU Engine(*)\Utilization Percentage` | Activity by GPU engine instance. Helps correlate rendering, video, or compute activity with a slowdown. Inspect engine and process instances rather than summing all percentages into one GPU total. |
| `\Network QoS Policy(*)\Packets dropped` | Drops reported by QoS policy instances. Helps investigate policy-related drops; it does not measure all packet loss across the network. |

For more detail, see Microsoft's guidance on [CPU and system performance investigation](https://learn.microsoft.com/en-us/troubleshoot/windows-server/support-tools/troubleshoot-issues-performance-monitor), [process memory leaks](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/using-performance-monitor-to-find-a-user-mode-memory-leak), and [processor power management](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/hardware/power/power-performance-tuning).

## Investigate an issue

1. Record the computer, incident time and time zone, affected application, and user activity. Preserve logs covering the period before, during, and after the issue.
2. Open `perfmon.exe` and select **Performance Monitor**. Open the graph properties, select **Source**, choose **Log files**, and add the saved performance log. Set the incident time range.
3. Add relevant counters from the log. Start with CPU, available memory, and disk latency, then narrow to process or device instances. Adjust graph scales or use report view when comparing different units.
4. Compare the incident with a normal period on the same machine. Correlate several counters rather than treating a single peak as the root cause.

| Symptom | Where to start |
| --- | --- |
| Application or desktop is slow | Compare processor busy time with per-process CPU and PID. Look for a saturated logical processor even when total CPU is moderate. |
| Performance worsens over hours | Compare available memory with growing Private Bytes for the same PID. Check Virtual Bytes for address-space growth; confirm suspected leaks with application-specific investigation. |
| File operations or application loading stall | Compare `C:` latency and queue length. These counters do not identify the process issuing the I/O. |
| Audio glitches or input lag | Check DPC and interrupt activity. If correlated, collect an ETW/WPR trace to identify the driver or routine involved. |
| Video or graphics are slow | Compare GPU engine activity with CPU and incident timing. High GPU utilization alone does not establish a GPU fault. |
| Transfers are slow | Compare adapter throughput, reported bandwidth, and QoS drops. Use network-specific tools to investigate latency, retransmissions, and remote bottlenecks. |

Fifteen-second samples show trends but can miss brief stalls or average away bursts. Disk coverage is limited to `C:`. This set does not record stack traces, file-level I/O, network latency, or a definitive paging history. Use it to narrow the next investigation, not as proof of causation. For finer-grained profiling, use Windows performance tracing; see [performance counter scope and limitations](https://learn.microsoft.com/en-us/windows/win32/perfctrs/about-performance-counters).

## Verification

Run isolated checks without installing or removing resources:

```powershell
.\tests\Test-BlackBox.ps1
```

On a test machine, install twice, verify logs receive samples, then reboot and confirm collection resumes without login. Test removal while collection is running, stopped, and already absent, and confirm logs remain. Isolated checks do not replace live PLA, Task Scheduler, and reboot verification.

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs or removes the BlackBox performance collector and startup task.
.EXAMPLE
.\Configure-BlackBox.ps1 -Action Install
.EXAMPLE
.\Configure-BlackBox.ps1 -Action Remove
.NOTES
Run with Windows PowerShell 5.1. Removal preserves all collected logs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Install', 'Remove')]
    [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Configuration: keep names derived from this single value.
$name = 'BlackBox'
$taskName = "Start $name"
$taskPath = '\'
$description = 'Performance counter collection for troubleshooting.'
$sampleInterval = 15
$segmentMaxSize = 300 # MB per segment, not a total retention limit.
$rootPath = '%systemdrive%\PerfLogs\Admin'
$counters = @(
    '\Process(*)\% Privileged Time'
    '\Process(*)\% Processor Time'
    '\Processor Information(*)\% Processor Time'
    '\Processor Information(*)\% of Maximum Frequency'
    '\Memory\Available MBytes'
    '\LogicalDisk(C:)\Current Disk Queue Length'
    '\LogicalDisk(C:)\Avg. Disk sec/Transfer'
    '\Network Interface(*)\Bytes Total/sec'
    '\Network Interface(*)\Current Bandwidth'
    '\Processor(*)\% DPC Time'
    '\Processor(*)\% Interrupt Time'
    '\Process(*)\ID Process'
    '\Process(*)\Private Bytes'
    '\Process(*)\Virtual Bytes'
    '\GPU Engine(*)\Utilization Percentage'
    '\Network QoS Policy(*)\Packets dropped'
)

function Get-AvailableCounterPaths {
    [CmdletBinding()]
    param([string[]]$Paths)
    $sets = @{}
    foreach ($path in $Paths) {
        try {
            if ($path -notmatch '^\\(?<Set>[^\\(]+)(?:\((?<Instance>.*)\))?\\(?<Counter>[^\\]+)$') {
                throw 'Expected a local counter path: \Set(instance)\Counter or \Set\Counter.'
            }
            $setName = $Matches.Set
            $instance = $Matches['Instance']
            $counterName = $Matches.Counter
            if (-not $sets.ContainsKey($setName)) {
                # Query metadata, not live samples: an invalid sample does not mean
                # that its counter is missing. Cache successful lookups per set.
                $sets[$setName] = @(Get-Counter -ListSet ([WildcardPattern]::Escape($setName)) -ErrorAction Stop |
                    Where-Object { $_.CounterSetName -eq $setName })
            }
            $metadata = $sets[$setName]
            $catalogPath = '\' + $setName
            if ($instance) { $catalogPath += '(*)' }
            $catalogPath += '\' + $counterName
            $knownPaths = @($metadata | ForEach-Object { $_.Paths })
            if ($knownPaths -notcontains $catalogPath) {
                throw 'Counter is not present in the installed counter catalog.'
            }
            if ($instance -and $instance -ne '*') {
                $instancePaths = @($metadata | ForEach-Object { $_.PathsWithInstances })
                if ($instancePaths -notcontains $path) {
                    throw 'The requested counter instance is not currently available.'
                }
            }
            # Preserve wildcard paths even when no instances are currently active.
            $path
        }
        catch {
            Write-Warning "Skipping '$path': $($_.Exception.Message)"
        }
    }
}

function Get-BlackBoxCollector {
    $collector = New-Object -ComObject Pla.DataCollectorSet
    try {
        $collector.Query($name, $null)
        return $collector
    }
    catch {
        # PowerShell can wrap COM exceptions in MethodInvocationException.
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception.HResult -eq -2144337918) { # PLA_E_DCS_NOT_FOUND: 0x80300002
                return $null
            }
            $exception = $exception.InnerException
        }
        throw
    }
}

function Stop-BlackBoxCollector {
    param([Parameter(Mandatory = $true)]$Collector)
    if ($Collector.Status -eq 1) {
        $Collector.Stop($true)
    }
    # Refuse to modify a collector that is starting, stopping, or undefined.
    if ($Collector.Status -ne 0) {
        throw "Collector '$name' is not stopped (status $($Collector.Status)); retry once its state settles."
    }
}

function Assert-CollectorValidation {
    [CmdletBinding()]
    param($Validation)
    $failures = @()
    if ($null -ne $Validation) {
        for ($i = 0; $i -lt $Validation.Count; $i++) {
            $item = $Validation.Item($i)
            $message = "$($item.Key): $($item.Description) (HRESULT $($item.Value))"
            if (([long]$item.Value -band 0x80000000L) -ne 0) {
                $failures += $message
            }
            elseif ([long]$item.Value -eq 0x00300100 -and
                ([string]$item.Key -match '^(?:/)?(?:DataCollectorSet/)?(?:TaskArguments|PerformanceCounterDataCollector\[1\]/LogAppend)$')) {
                # Expected with no PLA completion task and the retained overwrite
                # configuration. Keep other ignored-property notices visible.
                Write-Verbose $message
            }
            else {
                Write-Warning $message
            }
        }
    }
    if ($failures.Count -gt 0) {
        throw "Collector validation failed: $($failures -join '; ')"
    }
}

$stage = 'checking prerequisites'
$changes = [System.Collections.Generic.List[string]]::new()
try {
    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        throw 'Use Windows PowerShell 5.1 (powershell.exe), not PowerShell Core.'
    }
    Import-Module ScheduledTasks -ErrorAction Stop

    if ($Action -eq 'Remove') {
        $failures = [System.Collections.Generic.List[string]]::new()
        try {
            # Enumerate successfully before deciding a task is absent; do not hide access errors.
            $task = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
                $_.TaskName -eq $taskName -and $_.TaskPath -eq $taskPath
            })
            if ($task.Count -gt 0) {
                $task | Unregister-ScheduledTask -Confirm:$false -ErrorAction Stop
                $changes.Add("Removed task '$taskName'.")
            }
            else {
                Write-Host "Task '$taskName' is already absent."
            }
        }
        catch {
            $failures.Add("Task '$taskName' removal failed; it may remain: $($_.Exception.Message)")
        }

        try {
            $existing = Get-BlackBoxCollector
            if ($null -ne $existing) {
                Stop-BlackBoxCollector -Collector $existing
                $existing.Delete()
                $changes.Add("Deleted collector '$name'.")
            }
            else {
                Write-Host "Collector '$name' is already absent."
            }
        }
        catch {
            $failures.Add("Collector '$name' removal failed; it may remain: $($_.Exception.Message)")
        }
        $stage = 'removing resources'
        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
        Write-Host "SUCCESS: '$name' and its startup task are absent. Collected logs were preserved."
    }
    else {
        $stage = 'validating counter availability'
        $availableCounters = @(Get-AvailableCounterPaths -Paths $counters)
        if ($availableCounters.Count -eq 0) {
            throw 'No requested counters are available. Existing configuration was not changed.'
        }

        $stage = 'preparing collector configuration'
        $collector = New-Object -ComObject Pla.DataCollectorSet
        $collector.DisplayName = $name
        $collector.Description = $description
        $collector.SegmentMaxSize = $segmentMaxSize
        $collector.Segment = $true
        $collector.SubdirectoryFormat = 1
        $collector.RootPath = $rootPath
        $log = $collector.DataCollectors.CreateDataCollector(0) # plaPerformanceCounter
        $log.Name = $name
        $log.FileName = $env:COMPUTERNAME + '_'
        $log.FileNameFormat = 1 # plaPattern
        $log.FileNameFormatPattern = 'dddtt'
        $log.SampleInterval = $sampleInterval
        $log.LogOverwrite = $true
        $log.PerformanceCounters = [string[]]$availableCounters
        $collector.DataCollectors.Add($log)
        # plaValidateOnly: detect invalid configuration before stopping an existing set.
        Assert-CollectorValidation -Validation ($collector.Commit($name, $null, 0x1000))

        $stage = 'stopping existing collector'
        $existing = Get-BlackBoxCollector
        if ($null -ne $existing) {
            Stop-BlackBoxCollector -Collector $existing
            $changes.Add("Existing collector '$name' is stopped.")
        }

        $stage = 'saving collector configuration'
        $validation = $collector.Commit($name, $null, 3) # plaCreateOrModify
        $changes.Add("Collector '$name' commit completed; configuration may have changed.")
        Assert-CollectorValidation -Validation $validation

        $stage = 'registering startup task'
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\logman.exe" `
            -Argument ('start "{0}"' -f $name)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Trigger $trigger `
            -Action $taskAction -Principal $principal -Settings $settings `
            -Description "Start $name performance collection at system startup." -Force -ErrorAction Stop | Out-Null
        $changes.Add("Startup task '$taskName' registered.")

        $stage = 'starting and verifying collection'
        $collector.Start($true)
        $current = Get-BlackBoxCollector
        if ($null -eq $current -or $current.Status -ne 1) {
            throw "Collector '$name' did not reach running status."
        }
        Write-Host "SUCCESS: '$name' is running with $($availableCounters.Count) counter paths; '$taskName' is registered."
    }
    exit 0
}
catch {
    foreach ($change in $changes) { Write-Host $change }
    Write-Error "FAILED while ${stage}: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}

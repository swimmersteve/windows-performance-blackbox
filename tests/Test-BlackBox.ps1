# Isolated helper checks: never execute the script's installation/removal entry point.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tokens = $null
$parseErrors = $null
$path = Join-Path $PSScriptRoot '..\Configure-BlackBox.ps1'
$ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors -join '; ') }
foreach ($definition in $ast.FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($definition.Extent.Text))
}
$name = 'BlackBox'
function Get-Counter {
    [CmdletBinding()]
    param([string]$ListSet, [string]$Counter)
    if ($Counter) { throw 'Regression: availability validation must not sample counters.' }
    switch ($ListSet) {
        'Process' {
            [pscustomobject]@{
                CounterSetName = 'Process'
                Paths = @('\Process(*)\Private Bytes')
                PathsWithInstances = @()
            }
        }
        'Memory' {
            [pscustomobject]@{
                CounterSetName = 'Memory'
                Paths = @('\Memory\Available MBytes')
                PathsWithInstances = @('\Memory\Available MBytes')
            }
        }
        'LogicalDisk' {
            [pscustomobject]@{
                CounterSetName = 'LogicalDisk'
                Paths = @('\LogicalDisk(*)\Current Disk Queue Length')
                PathsWithInstances = @('\LogicalDisk(C:)\Current Disk Queue Length')
            }
        }
        default { throw 'Counter set unavailable' }
    }
}
$requested = @(
    '\Process(*)\Private Bytes', '\Memory\Available MBytes',
    '\LogicalDisk(C:)\Current Disk Queue Length', '\Process(*)\Nonexistent',
    '\LogicalDisk(Z:)\Current Disk Queue Length', '\Missing(*)\Counter'
)
$available = @(Get-AvailableCounterPaths $requested -WarningVariable counterWarnings -WarningAction SilentlyContinue)
if (($available -join '|') -ne ($requested[0..2] -join '|')) {
    throw 'Catalog validation did not preserve exactly the supported counter paths.'
}
if (@($counterWarnings).Count -ne 3) { throw 'Missing counters/instances must produce warnings.' }
function Assert-Throws {
    param([scriptblock]$Body, [string]$Pattern)
    try { & $Body }
    catch {
        if ($_.Exception.Message -notlike $Pattern) { throw }
        return
    }
    throw "Expected exception matching $Pattern"
}

$collector = [pscustomobject]@{ Status = 1; Stops = 0 }
$collector | Add-Member ScriptMethod Stop { param($wait) $this.Stops++; $this.Status = 0 }
Stop-BlackBoxCollector $collector
Stop-BlackBoxCollector $collector
if ($collector.Stops -ne 1) { throw 'Running/stopped state handling failed.' }
$collector.Status = 2
Assert-Throws { Stop-BlackBoxCollector $collector } '*not stopped*'
$collector.Status = 1
$collector | Add-Member ScriptMethod Stop { throw 'Stop denied' } -Force
Assert-Throws { Stop-BlackBoxCollector $collector } '*Stop denied*'

Assert-CollectorValidation $null
$validation = [pscustomobject]@{ Count = 1; Code = 0x00300103; Key = '/Test' }
$validation | Add-Member ScriptMethod Item {
    param($index)
    [pscustomobject]@{ Key = $this.Key; Value = $this.Code; Description = 'Test validation result' }
}
Assert-CollectorValidation $validation -WarningVariable warnings -WarningAction SilentlyContinue
if (@($warnings).Count -ne 1) { throw 'Validation warning was not reported.' }
$validation.Code = 0x80300103
Assert-Throws { Assert-CollectorValidation $validation } '*validation failed*'
$validation.Code = 0x00300100
foreach ($key in @('TaskArguments', 'PerformanceCounterDataCollector[1]/LogAppend')) {
    $validation.Key = $key
    $notices = @(Assert-CollectorValidation $validation -Verbose -WarningVariable warnings 4>&1)
    if (@($warnings).Count -ne 0 -or $notices.Count -ne 1 -or
        $notices[0] -isnot [System.Management.Automation.VerboseRecord]) {
        throw 'Expected ignored-property notice must be verbose only.'
    }
}
$validation.Key = '/UnexpectedProperty'
Assert-CollectorValidation $validation -WarningVariable warnings -WarningAction SilentlyContinue
if (@($warnings).Count -ne 1) { throw 'Unexpected ignored-property warning was hidden.' }
$validation.Key = 'TaskArguments'
$validation.Code = 0x80300101
Assert-Throws { Assert-CollectorValidation $validation } '*validation failed*'

# Replace COM construction only in this test scope.
function New-Object {
    param([string]$ComObject)
    return $script:fakeCollector
}
$script:fakeCollector = [pscustomobject]@{ FailureCode = [int]0x80300002 }
$script:fakeCollector | Add-Member ScriptMethod Query {
    param($collectorName, $server)
    if ($this.FailureCode -ne 0) {
        throw [System.Runtime.InteropServices.COMException]::new('Query failed', $this.FailureCode)
    }
}
if ($null -ne (Get-BlackBoxCollector)) { throw 'Missing collector was not recognized.' }
$script:fakeCollector.FailureCode = [int]0x80070005
Assert-Throws { Get-BlackBoxCollector } '*Query failed*'
$script:fakeCollector.FailureCode = 0
if ($null -eq (Get-BlackBoxCollector)) { throw 'Existing collector was not returned.' }
Write-Host 'PASS: syntax, stop states/failures, validation warnings/errors, missing collector and query failures.'

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Stepping stress test: 100 x Step Over through the loop in step_loop() (TestCpp\main.cpp) or
# StepLoop() (TestCSharp\Program.cs) while Watch 1 (i, sum), Locals and Call Stack are shown, so
# every step refreshes them and cancels the refresh of the step before. After every step, i and
# sum must show both radixes with matching numbers, and sum must be the sum of 0..i-1 or 0..i.
# Every 10th step, the values shown in the real windows are compared (read with UI Automation),
# and the display mode is switched every 20 steps.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\10_test_step_stress.ps1 [-Vs 2026] [-CSharp] [-Steps 100]
#
# Needs an unlocked desktop. -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$CSharp,
    [int]$Steps = 100,
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 900
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), $(if ($CSharp) { 'C#' } else { 'C++' }), $Steps steps ====="

$target = Get-TestTarget -CSharp:$CSharp
$function = if ($CSharp) { 'StepLoop' } else { 'step_loop' }
$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_STEP'))
$dbg.HexDisplayMode = $false
$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 180 'the BREAK_STEP breakpoint'
# Only Step Over moves on from here.
foreach ($bp in @($dbg.Breakpoints)) { $bp.Delete() }

$watcher = Start-DialogWatcher $session.Process.Id

# The number in "16 (0x00000010)" or "0x00000010 (16)"; both parts must agree.
function Get-Number([string]$What, [string]$Text) {
    if ($Text -match '^(\d+) \(0x([0-9a-f]+)\)$') { $dec = $Matches[1]; $hex = $Matches[2] }
    elseif ($Text -match '^0x([0-9a-f]+) \((\d+)\)$') { $hex = $Matches[1]; $dec = $Matches[2] }
    else { throw "$What shows '$Text', not a number in both radixes" }
    if ([Convert]::ToInt64($hex, 16) -ne [long]$dec) { throw "$What shows '$Text': the two radixes differ" }
    [long]$dec
}

function Get-TopFrame {
    $rows = (Get-DebugTree $session 'Call Stack').FindAll($UiScope::Children, [Windows.Automation.Condition]::TrueCondition)
    if ($rows.Count) { Get-RowValue $rows[0] } else { '' }
}

try {
    Clear-Watch $session
    Add-Watch $session $target.Source 'i', 'sum'
    $null = Get-DebugTree $session 'Locals'
    $null = Get-DebugTree $session 'Call Stack'

    $checked = 0
    for ($step = 1; $step -le $Steps; $step++) {
        if ($step % 20 -eq 0) { $dbg.HexDisplayMode = -not $dbg.HexDisplayMode }
        $dbg.StepOver($true)
        if ($dbg.CurrentMode -ne 2 -or $dbg.CurrentStackFrame.FunctionName -notmatch $function) {
            throw "step ${step}: not stopped in $function (mode $($dbg.CurrentMode), in $($dbg.CurrentStackFrame.FunctionName))"
        }
        $iText = $dbg.GetExpression('i', $true, 5000).Value
        $sumText = $dbg.GetExpression('sum', $true, 5000).Value
        $i = Get-Number "i at step $step" $iText
        $sum = Get-Number "sum at step $step" $sumText
        if ($sum -ne $i * ($i - 1) / 2 -and $sum -ne $i * ($i + 1) / 2) { throw "step ${step}: sum = $sum does not fit i = $i" }
        $checked++

        if ($step % 10 -eq 0) {
            # The windows must show the same text as a fresh evaluation.
            $shown = Wait-Value { Get-RowValue (Find-DebugRow (Get-DebugTree $session 'Watch 1') 'i') } $iText
            Assert-Value "i in Watch 1 at step $step" $shown $iText
            $shown = Wait-Value { Get-RowValue (Find-DebugRow (Get-DebugTree $session 'Locals') 'sum') } $sumText
            Assert-Value "sum in Locals at step $step" $shown $sumText
            $frame = Get-TopFrame
            Assert-True "Call Stack shows $function at step $step" ($frame -match $function) "- top frame: '$frame'"
        }
    }
    Assert-True "i and sum were correct after all $checked steps" ($checked -eq $Steps)
    $dbg.HexDisplayMode = $false

    $session.Process.Refresh()
    Assert-True 'Visual Studio still responds' $session.Process.Responding
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message)"
    $script:failures++
} finally {
    try { Clear-Watch $session } catch { }
    $messages = Stop-DialogWatcher $watcher
}
foreach ($m in $messages) { Assert-True 'no error message box' $false "- Visual Studio showed: $m" }

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Debugger features that Visual Studio calls on a row of Locals/Watch rather than on its value
# text: "Break When Value Changes" (C++), pinned members (C++ and C#) and "Make Object ID" (C#).
# For C/C++, AlwaysHex replaces every row with its own result object, so each of these features
# must be passed on to the expression evaluator's original result. C# rows are not replaced
# (AlwaysHex formats C# values on the server side), so there the features must simply keep working.
# This test makes sure they do.
#
# UI Automation selects the row in the Locals window, the command runs through DTE, and the
# outcome is checked through DTE. Error message boxes are recorded and closed automatically.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\5_test_result_features.ps1 [-Vs 2026] [-CSharp] [-Hex]
#
# -Hex runs everything with "Hexadecimal Display" on. -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$CSharp,
    [switch]$Hex,
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 300
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), $(if ($CSharp) { 'C#' } else { 'C++' }), HexDisplayMode = $([bool]$Hex) ====="

$target = Get-TestTarget -CSharp:$CSharp
# Pinning a member changes how its parent is summarized (TestCpp\main.cpp, TestCSharp\Program.cs).
if ($CSharp) {
    $member = 'pt/Y'; $unpinned = '{Point}'
    $pinned = if ($Hex) { 'Y = 0x012c (300)' } else { 'Y = 300 (0x012c)' }
} else {
    $member = 'pt/y'
    $unpinned = if ($Hex) { "{x=0x0000000a (10) y=0x012c (300) c=0x71 (113) 'q' ...}" } else { "{x=10 (0x0000000a) y=300 (0x012c) c=113 (0x71) 'q' ...}" }
    $pinned = if ($Hex) { '{y=0x012c (300) }' } else { '{y=300 (0x012c) }' }
}

$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_MAIN'))
$dbg.HexDisplayMode = [bool]$Hex
$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 120 'the BREAK_MAIN breakpoint'

$watcher = Start-DialogWatcher $session.Process.Id
$pin = 'DebuggerContextMenus.AutosWindow.PinMemberAsFavorite'
$getPt = { $dbg.GetExpression('pt', $true, 5000).Value }
try {
    # Pinned members are stored per type and survive the session: undo a pin left behind by
    # an earlier, interrupted run.
    if ((& $getPt) -ceq $pinned) { Invoke-RowCommand $session 'Locals' $member $pin }

    "===== Pin member $member ====="
    Assert-Value 'pt before pinning' (& $getPt) $unpinned
    Invoke-RowCommand $session 'Locals' $member $pin
    Assert-Value 'pt after pinning' (Wait-Value $getPt $pinned) $pinned
    Invoke-RowCommand $session 'Locals' $member $pin
    Assert-Value 'pt after unpinning' (Wait-Value $getPt $unpinned) $unpinned

    if ($CSharp) {
        '===== Make Object ID on h ====='
        Invoke-RowCommand $session 'Locals' 'h' 'DebuggerContextMenus.AutosWindow.MakeObjectID'
        $objectId = Wait-Value { $dbg.GetExpression('$1', $true, 5000).Value } '{Holder} {$1}'
        Assert-Value '$1' $objectId '{Holder} {$1}'
    } else {
        '===== Break When Value Changes on a ====='
        Invoke-RowCommand $session 'Locals' 'a' 'DebuggerContextMenus.AutosWindow.BreakWhenValueChanges'
        # dbgBreakpointLocationTypeData = 4
        $data = @($dbg.Breakpoints | Where-Object { $_.LocationType -eq 4 } | ForEach-Object { $_.Name })
        "  data breakpoints: $($data -join '; ')"
        Assert-True 'a data breakpoint on a exists' (@($data | Where-Object { $_ -match 'Original Expression: a\)' }).Count -eq 1)
    }
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message)"
    $script:failures++
} finally {
    # Never leave a pin behind, even when a check above failed.
    try { if ((& $getPt) -ceq $pinned) { Invoke-RowCommand $session 'Locals' $member $pin } } catch { }
    # Visual Studio keeps the display mode: leave it off.
    try { $dbg.HexDisplayMode = $false } catch { }
    $messages = Stop-DialogWatcher $watcher
}
foreach ($m in $messages) { Assert-True 'no error message box' $false "- Visual Studio showed: $m" }

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

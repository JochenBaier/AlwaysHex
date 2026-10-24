# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Return values in Autos (C++ only): after stepping over a call, Autos shows a row
# "make_point returned" / "twice returned". VS asks the EE for these rows directly
# (IDkmLanguageReturnValueEvaluator), so AlwaysHex wraps them like Watch results. Checks in
# return_values() (TestCpp\main.cpp):
#   - "make_point returned" (a struct) can be expanded, its members show both radixes;
#   - "twice returned" shows both radixes, in decimal and in hex display mode.
# Without the wrapping, the int row showed one radix and expanding the struct row came back to
# AlwaysHex with a result it had not created.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\14_test_return_values.ps1 [-Vs 2026]
#
# Needs an unlocked desktop. -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 600
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), C++, return values ====="

$target = Get-TestTarget
$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_RETURN'))
$dbg.HexDisplayMode = $false
$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 180 'the BREAK_RETURN breakpoint'
foreach ($bp in @($dbg.Breakpoints)) { $bp.Delete() }

$watcher = Start-DialogWatcher $session.Process.Id

# The top-level Autos row whose name contains "<function>" and "returned".
function Find-ReturnRow([string]$Function) {
    $tree = Get-DebugTree $session 'Autos'
    foreach ($row in $tree.FindAll($UiScope::Children, (New-UiCondition $UiElement::ClassNameProperty 'TreeGridItem'))) {
        if ($row.Current.Name -like "*$Function*returned*") { return $row }
    }
    throw "no '$Function ... returned' row in Autos"
}

# Value of a member of an expanded row.
function Get-ChildValue($Row, [string]$Name) {
    $cond = New-Object Windows.Automation.AndCondition(
        (New-UiCondition $UiElement::NameProperty $Name),
        (New-UiCondition $UiElement::ClassNameProperty 'TreeGridItem'))
    $child = $Row.FindFirst($UiScope::Descendants, $cond)
    if (-not $child) { throw "member '$Name' not found under '$($Row.Current.Name)'" }
    Get-RowValue $child
}

try {
    # Step over "Point rp = make_point(42);".
    $dbg.StepOver($true)
    $null = Get-DebugTree $session 'Autos'
    $row = $null
    $deadline = (Get-Date).AddSeconds(15)
    while (-not $row -and (Get-Date) -lt $deadline) {
        try { $row = Find-ReturnRow 'make_point' } catch { Start-Sleep -Milliseconds 500 }
    }
    if (-not $row) { $row = Find-ReturnRow 'make_point' }
    Assert-True "Autos shows '$($row.Current.Name)'" $true
    $row.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
    $x = Wait-Value { Get-ChildValue (Find-ReturnRow 'make_point') 'x' } '42 (0x0000002a)'
    Assert-Value 'make_point returned / x' $x '42 (0x0000002a)'
    $y = Wait-Value { Get-ChildValue (Find-ReturnRow 'make_point') 'y' } '43 (0x002b)'
    Assert-Value 'make_point returned / y' $y '43 (0x002b)'

    # Step over "int rt = twice(21);".
    $dbg.StepOver($true)
    $shown = Wait-Value { Get-RowValue (Find-ReturnRow 'twice') } '42 (0x0000002a)' 15
    Assert-Value 'twice returned' $shown '42 (0x0000002a)'
    $dbg.HexDisplayMode = $true
    $shown = Wait-Value { Get-RowValue (Find-ReturnRow 'twice') } '0x0000002a (42)' 15
    Assert-Value 'twice returned (hex display)' $shown '0x0000002a (42)'
    $dbg.HexDisplayMode = $false

    $session.Process.Refresh()
    Assert-True 'Visual Studio still responds' $session.Process.Responding
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message)"
    $script:failures++
} finally {
    $dbg.HexDisplayMode = $false
    # Visual Studio keeps the layout: an open Autos window would evaluate expressions in the
    # other tests (see Close-AutosWindow).
    Close-AutosWindow $session
    $messages = Stop-DialogWatcher $watcher
}
foreach ($m in $messages) { Assert-True 'no error message box' $false "- Visual Studio showed: $m" }

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

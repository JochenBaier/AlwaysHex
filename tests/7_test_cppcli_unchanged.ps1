# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# C++/CLI must look exactly as without AlwaysHex. AlwaysHex handles C and C++ in native code
# only; C++/CLI (C++ on the .NET runtime) has its own expression evaluator, and forwarding to it
# would switch its display to C# style ("{string[0]}" instead of "array<System::String^>(0)").
# This test debugs tests\bin\TestCppCli.exe and checks values, types, Locals and the Call Stack
# in both display modes: single radix only, and the C++/CLI type names.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\7_test_cppcli_unchanged.ps1 [-Vs 2026]
#
# Needs the Visual Studio component "C++/CLI support". -KeepOpen leaves Visual Studio running.
param(
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 300
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), C++/CLI ====="

$target = Get-TestTarget -CppCli
$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_MAIN'))
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_ADD'))
$dbg.HexDisplayMode = $false
$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 120 'the BREAK_MAIN breakpoint'

function Get-Local([string]$Name) {
    foreach ($v in $dbg.CurrentStackFrame.Locals) { if ($v.Name -eq $Name) { return $v.Value } }
}

try {
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== HexDisplayMode = $hex : main() ====="
        Assert-Value 'a' $dbg.GetExpression('a', $true, 5000).Value $(if ($hex) { '0x00000064' } else { '100' })
        Assert-Value 's16' $dbg.GetExpression('s16', $true, 5000).Value $(if ($hex) { '0xffd6' } else { '-42' })
        Assert-Value 'a (Locals)' (Get-Local 'a') $(if ($hex) { '0x00000064' } else { '100' })
        Assert-Value 'type of box' $dbg.GetExpression('box', $true, 5000).Type 'Box^'
        Assert-Value 'type of text' $dbg.GetExpression('text', $true, 5000).Type 'System::String^'
        Assert-Value 'args (Locals)' (Get-Local 'args') $(if ($hex) { 'array<System::String^>(0x00000000)' } else { 'array<System::String^>(0)' })
    }

    $dbg.HexDisplayMode = $false
    $dbg.Go($false)
    Wait-Until { $dbg.CurrentMode -eq 2 -and $dbg.CurrentStackFrame.FunctionName -match 'add' } 60 'the BREAK_ADD breakpoint'
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== HexDisplayMode = $hex : Call Stack in add() ====="
        $expected = if ($hex) { 'add(int lhs=0x00000064, short rhs=0xffd6)' } else { 'add(int lhs=100, short rhs=-42)' }
        $frame = ''
        $deadline = (Get-Date).AddSeconds(10)
        do {
            $rows = (Get-DebugTree $session 'Call Stack').FindAll($UiScope::Children, [Windows.Automation.Condition]::TrueCondition)
            $frame = if ($rows.Count) { Get-RowValue $rows[0] } else { '' }
            if ($frame.Contains($expected)) { break }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        "  top frame: $frame"
        Assert-True "top frame shows $expected" $frame.Contains($expected)
    }
    $dbg.HexDisplayMode = $false
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message)"
    $script:failures++
}

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Repeats "start debugging -> stop at BREAK_MAIN -> evaluate -> stop debugging" several
# times in one experimental VS session, to catch problems that only show up on the second
# and later debug sessions. Each round must stop at the breakpoint and show a = 100 in both
# radixes; any failure ends with exit code 1.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\4_test_debug_restart.ps1 [-Vs 2026] [-CSharp] [-Rounds 3]
param(
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [switch]$CSharp,
    [int]$Rounds = 3,
    [int]$WatchdogSec = 300
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), $Rounds rounds ====="

$target = Get-TestTarget -CSharp:$CSharp
$session = Start-ExpVs $target.Exe
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -Command Start-Sleep -Seconds $WatchdogSec; Stop-Process -Id $($session.Process.Id) -Force -ErrorAction SilentlyContinue"
$dte = $session.Dte
$dbg = $dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_MAIN'))

# dbgDesignMode = 1, dbgBreakMode = 2, dbgRunMode = 3
$failures = 0
for ($round = 1; $round -le $Rounds; $round++) {
    $dbg.Go($false)
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and $dbg.CurrentMode -ne 2) {
        Start-Sleep -Milliseconds 500
        # Back in design mode after Go means the program ran to its end without stopping.
        if ($dbg.CurrentMode -eq 1 -and (Get-Date) -gt $deadline.AddSeconds(-55)) { break }
    }
    $mode = $dbg.CurrentMode
    if ($mode -eq 2) {
        $dbg.HexDisplayMode = $false
        $a = $dbg.GetExpression('a', $true, 5000).Value
        if ($a -ceq '100 (0x00000064)') {
            "round ${round}: stopped at breakpoint, a = $a"
        } else {
            "round ${round}: FAIL, a = '$a', expected '100 (0x00000064)'"
            $failures++
        }
        $dbg.Stop($true)
        Wait-Until { $dbg.CurrentMode -eq 1 } 60 'debugging to stop'
    } else {
        "round ${round}: FAIL, did not stop at the breakpoint (mode $mode)"
        $failures++
    }
}
Stop-ExpVsSession $session
if ($failures) {
    "===== $failures round(s) FAILED ====="
    exit 1
}
'===== all rounds passed ====='

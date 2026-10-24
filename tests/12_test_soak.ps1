# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Soak test: thousands of evaluations, expansions and Locals reads at BREAK_MAIN, to find leaks
# and slowdowns. AlwaysHex creates and closes two evaluation results for every value; anything it
# fails to close stays in memory. Checks:
#   - every 100th evaluation of "a" still shows "100 (0x00000064)",
#   - Visual Studio's private memory grows by less than -MaxGrowthMB between the end of the
#     warm-up and the end of the run,
#   - the last block of 500 evaluations is at most 3 times slower than the first one,
#   - no error message boxes, and Visual Studio still responds.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\12_test_soak.ps1 [-Vs 2026] [-CSharp] [-Evaluations 5000]
#
# -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$CSharp,
    [int]$Evaluations = 5000,
    [int]$MaxGrowthMB = 300,
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 1200
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), $(if ($CSharp) { 'C#' } else { 'C++' }), $Evaluations evaluations ====="

$target = Get-TestTarget -CSharp:$CSharp
if ($CSharp) {
    $expressions = 'a', 'pt', 'arr', 'ch', 'h', 'll', 'pt.Y', 'arr[1]', 'a + 1', 'str', 'col', 'h.Prop'
} else {
    $expressions = 'a', 'pt', 'arr', 'ch', 'p', 'll', 'pt.y', 'arr[1]', 'a + 1', 'str', 'col', 'ull'
}
$warmup = 500
$block = 500

$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_MAIN'))
$dbg.HexDisplayMode = $false
$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 180 'the BREAK_MAIN breakpoint'

function Get-VsMemoryMB {
    # Release the evaluation results this script still holds, so Visual Studio can free them.
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 2
    $session.Process.Refresh()
    [int]($session.Process.PrivateMemorySize64 / 1MB)
}

$watcher = Start-DialogWatcher $session.Process.Id
$stopwatch = New-Object Diagnostics.Stopwatch
$blockTimes = New-Object Collections.Generic.List[double]
try {
    $startMB = Get-VsMemoryMB
    $wrong = 0
    $stopwatch.Start()
    for ($n = 1; $n -le $Evaluations; $n++) {
        $r = $dbg.GetExpression($expressions[$n % $expressions.Count], $true, 5000)
        $null = $r.Value
        # Every 10th: expand the result and read its children.
        if ($n % 10 -eq 0) { foreach ($m in $r.DataMembers) { $null = $m.Value } }
        if ($n % 100 -eq 0) {
            $a = $dbg.GetExpression('a', $true, 5000).Value
            if ($a -cne '100 (0x00000064)') { $wrong++; "  wrong value at evaluation ${n}: a = '$a'" }
            foreach ($v in $dbg.CurrentStackFrame.Locals) { $null = $v.Value }
            [GC]::Collect()
        }
        if ($n % $block -eq 0) {
            $stopwatch.Stop()
            $blockTimes.Add($stopwatch.Elapsed.TotalMilliseconds / $block)
            '  evaluations {0,5}: {1,5:N1} ms each' -f $n, $blockTimes[$blockTimes.Count - 1]
            if ($n -eq $warmup) {
                $warmMB = Get-VsMemoryMB
                "  memory after warm-up: $warmMB MB (at start $startMB MB)"
            }
            $stopwatch.Restart()
        }
    }
    $endMB = Get-VsMemoryMB
    "  memory at the end: $endMB MB"

    Assert-True "a showed '100 (0x00000064)' at every check" ($wrong -eq 0) "- $wrong wrong values"
    Assert-True "memory grew by $($endMB - $warmMB) MB after the warm-up (limit $MaxGrowthMB MB)" (($endMB - $warmMB) -lt $MaxGrowthMB)
    # Blocks after the warm-up: the last one may not be much slower than the first one.
    $first = $blockTimes[1]
    $last = $blockTimes[$blockTimes.Count - 1]
    Assert-True ('the last block took {0:N1} ms per evaluation, the first {1:N1} ms (limit: 3 times)' -f $last, $first) ($last -le 3 * $first)
    $session.Process.Refresh()
    Assert-True 'Visual Studio still responds' $session.Process.Responding
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message)"
    $script:failures++
} finally {
    $messages = Stop-DialogWatcher $watcher
}
foreach ($m in $messages) { Assert-True 'no error message box' $false "- Visual Studio showed: $m" }

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

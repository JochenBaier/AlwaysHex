# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Large and deeply nested data: a vector/array with 100,000 elements, an int[20000], a map with
# 1,000 entries, 2D and jagged arrays, a struct nested 10 levels deep and a linked list followed
# 100 nodes deep (big_data() in TestCpp\main.cpp, BigData() in TestCSharp\Program.cs).
# Checks the values at high indices and deep levels, the number of children (C#: all 100,000
# array elements, the last one read as a child), and that every step stays within a generous
# time limit, in both display modes.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\8_test_large_data.ps1 [-Vs 2026] [-CSharp]
#
# The time limits are about ten times what AlwaysHex needs on a typical developer machine;
# -BudgetFactor 2 doubles them for a slow machine. -KeepOpen leaves Visual Studio running.
param(
    [switch]$CSharp,
    [double]$BudgetFactor = 1,
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 600
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), $(if ($CSharp) { 'C#' } else { 'C++' }) ====="

$target = Get-TestTarget -CSharp:$CSharp
$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_BIG'))
$dbg.HexDisplayMode = $false
$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 180 'the BREAK_BIG breakpoint'

# "100 (0x00000064)" in decimal mode, "0x00000064 (100)" in hex mode.
function Dual([long]$Value, [int]$Digits) {
    $h = '0x' + $Value.ToString('x' + $Digits)
    if ($script:hex) { "$h ($Value)" } else { "$Value ($h)" }
}

# The name of an element row: "[40000]", or "[0x00009c40]" in hex mode (C++ only).
function Index {
    $parts = foreach ($i in $args) { if ($script:hex -and -not $CSharp) { '0x' + ([int]$i).ToString('x8') } else { "$i" } }
    '[' + ($parts -join ', ') + ']'
}

$stopwatch = New-Object Diagnostics.Stopwatch
# Runs $Do, prints how long it took and fails the check if that is above the limit.
function Measure-Step([string]$What, [int]$BudgetMs, [scriptblock]$Do) {
    $budget = [int]($BudgetMs * $BudgetFactor)
    $stopwatch.Restart()
    $result = & $Do
    $stopwatch.Stop()
    $ms = $stopwatch.ElapsedMilliseconds
    if ($ms -le $budget) { '  CHECK ok    {0}: {1:N0} ms (limit {2:N0} ms)' -f $What, $ms, $budget }
    else { '  CHECK FAIL  {0}: {1:N0} ms, limit {2:N0} ms' -f $What, $ms, $budget; $script:failures++ }
    $script:result = $result
}

function Get-Child($Result, [string]$Name) {
    foreach ($m in $Result.DataMembers) { if ($m.Name -eq $Name) { return $m } }
    throw "no child '$Name' in $($Result.Name)"
}

function Get-Eval([string]$Expression) { $dbg.GetExpression($Expression, $true, 60000) }

try {
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== HexDisplayMode = $hex ====="

        Measure-Step 'evaluate big' 5000 { Get-Eval 'big' }
        $big = $result
        if ($CSharp) {
            Assert-Value 'big' $big.Value $(if ($hex) { '{int[0x000186a0]}' } else { '{int[100000]}' })
        } else {
            Assert-Value 'big' $big.Value "{ size=$(Dual 100000 16) }"
        }
        Measure-Step 'count the children of big' 5000 { $big.DataMembers.Count }
        $count = $result
        if ($CSharp) {
            # C#: all 100,000 elements are children; the last one must be reachable by
            # enumeration (big[99999] below is a separate evaluation, not a child).
            Assert-Value 'children of big' "$count" '100000'
            Measure-Step 'read big[99999] as the last child' 5000 { $big.DataMembers.Item($big.DataMembers.Count) }
            Assert-Value 'last child of big' "$($result.Name) = $($result.Value)" "$(Index 99999) = $(Dual 99999 8)"
        } else {
            # C++: Visual Studio shows the first 50,000 elements and a "[More]" node.
            Assert-True "big has $count children" ($count -ge 50000)
        }
        Measure-Step 'read big[0] and big[40000] as children' 5000 {
            $items = $big.DataMembers
            # The elements follow [capacity] and [allocator] in C++.
            $first = 1
            while ($first -lt 5 -and $items.Item($first).Name -ne (Index 0)) { $first++ }
            $items.Item($first), $items.Item($first + 40000)
        }
        Assert-Value 'child [0]' "$($result[0].Name) = $($result[0].Value)" "$(Index 0) = $(Dual 0 8)"
        Assert-Value 'child [40000]' "$($result[1].Name) = $($result[1].Value)" "$(Index 40000) = $(Dual 40000 8)"
        Measure-Step 'evaluate big[99999]' 2000 { (Get-Eval 'big[99999]').Value }
        Assert-Value 'big[99999]' $result (Dual 99999 8)

        if ($CSharp) {
            Measure-Step 'evaluate list and count its children' 5000 { $l = Get-Eval 'list'; $l.Value, $l.DataMembers.Count }
            Assert-Value 'list' $result[0] "Count = $(Dual 100000 8)"
            Assert-Value 'children of list' $result[1] '100001'
            Measure-Step 'grid[2, 3] as a child' 3000 { $g = Get-Eval 'grid'; $g.DataMembers.Item($g.DataMembers.Count) }
            Assert-Value 'last child of grid' "$($result.Name) = $($result.Value)" "$(Index 2 3) = $(Dual 35 8)"
            Measure-Step 'jagged[1][0] as a child' 3000 { (Get-Eval 'jagged').DataMembers.Item(2).DataMembers.Item(1) }
            Assert-Value 'jagged[1][0]' "$($result.Name) = $($result.Value)" "$(Index 0) = $(Dual 300 8)"
            Measure-Step 'evaluate bigmap and count its children' 5000 { $m = Get-Eval 'bigmap'; $m.Value, $m.DataMembers.Count }
            Assert-Value 'bigmap' $result[0] "Count = $(Dual 1000 8)"
            Assert-Value 'children of bigmap' $result[1] '1001'
        } else {
            Measure-Step 'all children of g_huge (int[20000])' 5000 { $c = (Get-Eval 'g_huge').DataMembers; $c.Count, $c.Item($c.Count) }
            Assert-Value 'children of g_huge' $result[0] '20000'
            Assert-Value 'last child of g_huge' "$($result[1].Name) = $($result[1].Value)" "$(Index 19999) = $(Dual 19999 8)"
            Measure-Step 'grid[2][3] as a child' 3000 { (Get-Eval 'grid').DataMembers.Item(3).DataMembers.Item(4) }
            Assert-Value 'grid[2][3]' "$($result.Name) = $($result.Value)" "$(Index 3) = $(Dual 35 8)"
            Measure-Step 'evaluate bigmap and count its children' 10000 { $m = Get-Eval 'bigmap'; $m.Value, $m.DataMembers }
            Assert-Value 'bigmap' $result[0] "{ size=$(Dual 1000 16) }"
            $children = $result[1]
            Assert-Value 'children of bigmap' $children.Count '1003'
            # [comparator], [allocator], [0] ... [999], [Raw View]
            $last = $children.Item($children.Count - 1)
            Assert-Value 'bigmap[999] as a child' "$($last.Name) = $($last.Value)" "$(Index 999) = $(Dual 1998 8)"
        }

        Measure-Step 'deep: 10 levels down' 5000 {
            $r = Get-Eval 'deep'
            for ($i = 0; $i -lt 9; $i++) { $r = Get-Child $r 'n' }
            (Get-Child $r 'v').Value
        }
        Assert-Value 'v at level 9' $result (Dual 9 8)
        Measure-Step 'linked list: 100 nodes down' 25000 {
            $r = Get-Eval 'head'
            for ($i = 0; $i -lt 100; $i++) { $r = Get-Child $r 'next' }
            (Get-Child $r 'v').Value
        }
        Assert-Value 'v of node 100' $result (Dual 100 8)
        Measure-Step 'Locals of the function' 3000 { @($dbg.CurrentStackFrame.Locals) }
        Assert-True "Locals has $($result.Count) rows" ($result.Count -ge 5)
    }
    $dbg.HexDisplayMode = $false

    $session.Process.Refresh()
    Assert-True 'Visual Studio still responds' $session.Process.Responding
    "  Visual Studio private memory: $([int]($session.Process.PrivateMemorySize64 / 1MB)) MB"
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message)"
    $script:failures++
}

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

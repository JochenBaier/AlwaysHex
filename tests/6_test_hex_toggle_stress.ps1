# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Stress test: switches "Hexadecimal Display" on and off many times in quick succession while
# the Watch 1, Locals and Call Stack windows are being filled. Visual Studio cancels the
# evaluations that are still running at every switch; AlwaysHex must handle that without error
# messages, hangs or wrong values. Afterwards the values shown in the real windows are checked
# (read with UI Automation) in both display modes.
# C#: finally the same with AllTypes() in TestCSharp\Program.cs, where Locals holds about 150
# variables of many .NET types (all numeric minimum/maximum values, dates, collections, LINQ
# results, DataTable, XML, regular expressions, streams, exceptions, ...): each checked row must
# show exactly what a fresh evaluation shows, and every integer both radixes.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\6_test_hex_toggle_stress.ps1 [-Vs 2026] [-CSharp] [-Toggles 100]
#
# -Toggles is the number of switches with Watch 1 shown; Locals and Call Stack get half of it
# each. -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$CSharp,
    [int]$Toggles = 100,
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 900
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), $(if ($CSharp) { 'C#' } else { 'C++' }), $Toggles switches ====="

$target = Get-TestTarget -CSharp:$CSharp
# What the windows must show afterwards (TestCpp\main.cpp, TestCSharp\Program.cs).
$watchNames = 'a', 'ch', 'pt'
if ($CSharp) {
    $expected = @{
        $false = @{ 'a' = '100 (0x00000064)'; 'ch' = "97 (0x0061) 'a'"; 'frame' = 'lhs = 100 \(0x00000064\)' }
        $true  = @{ 'a' = '0x00000064 (100)'; 'ch' = "0x0061 (97) 'a'"; 'frame' = 'lhs = 0x00000064 \(100\)' }
    }
} else {
    $expected = @{
        $false = @{ 'a' = '100 (0x00000064)'; 'ch' = "97 (0x61) 'a'"; 'frame' = 'lhs=100 \(0x00000064\)' }
        $true  = @{ 'a' = '0x00000064 (100)'; 'ch' = "0x61 (97) 'a'"; 'frame' = 'lhs=0x00000064 \(100\)' }
    }
}

$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_MAIN'))
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_ADD'))
if ($CSharp) { $null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_TYPES')) }
$dbg.HexDisplayMode = $false
$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 120 'the BREAK_MAIN breakpoint'

$watcher = Start-DialogWatcher $session.Process.Id
$random = New-Object Random 42

# Switches the display mode $Count times, with a random pause of 0..120 ms between switches,
# so that the switches hit different stages of the window refresh.
function Switch-HexDisplay([int]$Count) {
    for ($i = 0; $i -lt $Count; $i++) {
        $dbg.HexDisplayMode = -not $dbg.HexDisplayMode
        Start-Sleep -Milliseconds $random.Next(0, 121)
    }
}

# The value of a top-level row in Watch 1 as the window shows it.
function Get-WatchValue([string]$Name) {
    Get-RowValue (Find-DebugRow (Get-DebugTree $session 'Watch 1') $Name)
}

try {
    Clear-Watch $session
    Add-Watch $session $target.Source $watchNames

    "===== Watch 1: $Toggles switches ====="
    $null = Get-DebugTree $session 'Watch 1'
    Switch-HexDisplay $Toggles
    "===== Locals: $([int]($Toggles / 2)) switches ====="
    $null = Get-DebugTree $session 'Locals'
    Switch-HexDisplay ([int]($Toggles / 2))

    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== Watch 1 afterwards, HexDisplayMode = $hex ====="
        foreach ($name in 'a', 'ch') {
            Assert-Value "$name (Watch 1)" (Wait-Value { Get-WatchValue $name } $expected[$hex][$name]) $expected[$hex][$name]
        }
        # The struct summary must look exactly like a fresh evaluation.
        $fresh = $dbg.GetExpression('pt', $true, 5000).Value
        Assert-Value 'pt (Watch 1)' (Wait-Value { Get-WatchValue 'pt' } $fresh) $fresh
    }

    $dbg.HexDisplayMode = $false
    $dbg.Go($false)
    Wait-Until { $dbg.CurrentMode -eq 2 -and $dbg.CurrentStackFrame.FunctionName -match 'add' } 60 'the BREAK_ADD breakpoint'
    "===== Call Stack: $([int]($Toggles / 2)) switches ====="
    $null = Get-DebugTree $session 'Call Stack'
    Switch-HexDisplay ([int]($Toggles / 2))
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== Call Stack afterwards, HexDisplayMode = $hex ====="
        $frame = ''
        $deadline = (Get-Date).AddSeconds(10)
        do {
            $rows = (Get-DebugTree $session 'Call Stack').FindAll($UiScope::Children, [Windows.Automation.Condition]::TrueCondition)
            $frame = if ($rows.Count) { Get-RowValue $rows[0] } else { '' }
            if ($frame -match $expected[$hex]['frame']) { break }
            Start-Sleep -Milliseconds 300
        } while ((Get-Date) -lt $deadline)
        "  top frame: $frame"
        Assert-True "top frame shows $($expected[$hex]['frame'] -replace '\\', '')" ($frame -match $expected[$hex]['frame'])
    }
    $dbg.HexDisplayMode = $false

    Assert-Value 'lhs (evaluated afterwards)' $dbg.GetExpression('lhs', $true, 5000).Value $expected[$false]['a']

    if ($CSharp) {
        $dbg.Go($false)
        Wait-Until { $dbg.CurrentMode -eq 2 -and $dbg.CurrentStackFrame.FunctionName -match 'AllTypes' } 60 'the BREAK_TYPES breakpoint'
        "===== AllTypes, Locals: $([int]($Toggles / 2)) switches ====="
        $null = Get-DebugTree $session 'Locals'
        Switch-HexDisplay ([int]($Toggles / 2))
        # Integer variables must show both radixes.
        $integers = 'sbMin', 'sbMax', 'bMin', 'bMax', 'sMin', 'sMax', 'usMin', 'usMax', 'iMin', 'iMax', 'uiMin', 'uiMax',
                    'lMin', 'lMax', 'ulMin', 'ulMax', 'nullableValue', 'boxedInteger', 'streamLength', 'streamPosition',
                    'listCount', 'listMin', 'listMax', 'dictionaryCount', 'matrixValue'
        $dual = '^(-?\d+ \(0x[0-9a-f]+\)|0x[0-9a-f]+ \(-?\d+\))$'
        foreach ($hex in $false, $true) {
            $dbg.HexDisplayMode = $hex
            "===== AllTypes afterwards, HexDisplayMode = $hex ====="
            # All locals as the Locals window gets them (GetFrameLocals) against a fresh evaluation.
            # DTE's frame locals do not call ToString(), so objects may show just "{Type.Name}".
            $count = 0
            foreach ($v in $dbg.CurrentStackFrame.Locals) {
                $fresh = $dbg.GetExpression($v.Name, $true, 10000).Value
                if ($v.Value -cne $fresh -and $v.Value -notmatch '^\{[\w.]+\}$') { Assert-Value "$($v.Name) (frame locals)" $v.Value $fresh }
                if ($v.Name -in $integers -and $v.Value -notmatch $dual) { Assert-True "$($v.Name) shows both radixes" $false "- shows '$($v.Value)'" }
                $count++
            }
            Assert-True "all $count locals match a fresh evaluation" ($count -ge 100)
            # The rows the Locals window shows (only the visible part of the list exists), once it
            # shows this function's variables.
            $deadline = (Get-Date).AddSeconds(20)
            do {
                $rows = @((Get-DebugTree $session 'Locals').FindAll($UiScope::Children, [Windows.Automation.Condition]::TrueCondition))
                if ($rows.Count -and $rows[0].Current.Name -eq 'sbMin') { break }
                Start-Sleep -Milliseconds 300
            } while ((Get-Date) -lt $deadline)
            Assert-True "the Locals window shows the variables of AllTypes ($($rows.Count) rows visible)" ($rows.Count -and $rows[0].Current.Name -eq 'sbMin')
            foreach ($row in $rows) {
                $name = $row.Current.Name
                if (-not $name) { continue }
                $fresh = $dbg.GetExpression($name, $true, 10000).Value
                Assert-Value "$name (Locals window)" (Wait-Value { Get-RowValue $row } $fresh) $fresh
            }
            foreach ($name in 'sbMin', 'sMin', 'iMin', 'ulMax') { "  $name = $($dbg.GetExpression($name, $true, 5000).Value)" }
        }
        $dbg.HexDisplayMode = $false
    }

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

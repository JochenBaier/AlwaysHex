# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Features that use an expression's value instead of showing it, and so must not get the
# merged "100 (0x00000064)" text: tracepoint messages, breakpoint conditions, and (C++) data
# breakpoints and the Memory/Disassembly "Address" box with an integer that holds an address.
# Checks that each one is accepted and works:
#   - Tracepoint at BREAK_MAIN: "{a}" shows both radixes, "{a,d}" (C++) or "{a.ToString(),nq}"
#     (C#) one, see README.
#   - Conditional breakpoint "i == 0x10" in the loop of step_loop()/StepLoop() stops at i = 16.
#   - C++: data breakpoints on "addr" (an integer holding &g_counter) and on "&local", the
#     Memory window at "addr", the Disassembly window at "code+2" (code holds &twice), and a
#     breakpoint at the address of twice(). The program then stops in twice() and when
#     g_counter changes. (Visual Studio itself only accepts a literal address for an address
#     breakpoint, and keeps a plain variable name like "code" in the Disassembly box.)
# Error message boxes are recorded and count as failures.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\9_test_breakpoints.ps1 [-Vs 2026] [-CSharp]
#
# The Memory and Disassembly windows need UI Automation and an unlocked desktop: the address is
# typed into the box as keystrokes, and only while Visual Studio has the keyboard focus.
# -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$CSharp,
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 400
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Add-Type -AssemblyName System.Windows.Forms
Use-Vs $Vs
"===== $($VsInfo.Name), $(if ($CSharp) { 'C#' } else { 'C++' }) ====="

# Breakpoint2.Message/BreakWhenHit and DTE2.ToolWindows are not reachable through PowerShell's
# late binding; the typed interfaces are used through reflection.
$envdte80 = [Reflection.Assembly]::LoadFrom((Join-Path $VsInfo.Root 'Common7\IDE\PublicAssemblies\envdte80.dll'))

$target = Get-TestTarget -CSharp:$CSharp
$src = $target.Source
if ($CSharp) {
    $message = 'TP a={a} s={a.ToString(),nq} y={pt.Y}'
    $traceLine = 'TP a=100 (0x00000064) s=100 y=300 (0x012c)'
} else {
    $message = 'TP a={a} ad={a,d} y={pt.y}'
    $traceLine = 'TP a=100 (0x00000064) ad=100 y=300 (0x012c)'
}

$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dte = $session.Dte
$dbg = $dte.Debugger
$dbg.HexDisplayMode = $false

# Breakpoints.Add(Function, File, Line, Column, Condition, ConditionType, Language, Data,
#                 DataCount, Address); ConditionType 1 = when true.
$mainLine = Get-MarkerLine $src 'BREAK_MAIN'
$null = $dbg.Breakpoints.Add('', $src, $mainLine)
foreach ($bp in $dbg.Breakpoints) {
    if ($bp.FileLine -eq $mainLine) {
        $type = $envdte80.GetType('EnvDTE80.Breakpoint2')
        $type.GetProperty('Message').SetValue($bp, $message)
        $type.GetProperty('BreakWhenHit').SetValue($bp, $false)
    }
}
$null = $dbg.Breakpoints.Add('', $src, (Get-MarkerLine $src 'BREAK_STEP'), 1, 'i == 0x10', 1)
if (-not $CSharp) { $null = $dbg.Breakpoints.Add('', $src, (Get-MarkerLine $src 'BREAK_ADDR')) }

# The text of the Debug pane in the Output window.
function Get-DebugOutput {
    $toolWindows = $envdte80.GetType('EnvDTE80.DTE2').GetProperty('ToolWindows').GetValue($dte)
    $doc = $toolWindows.OutputWindow.OutputWindowPanes.Item('Debug').TextDocument
    $doc.StartPoint.CreateEditPoint().GetText($doc.EndPoint)
}

# Types $Keys (SendKeys syntax) into an "Address:" box and presses Enter; returns what the box
# shows afterwards. The keys are only sent while the box has the keyboard focus, so that they
# can never reach another program.
function Set-AddressBox($Edit, [string]$Keys) {
    $Edit.SetFocus()
    Start-Sleep -Milliseconds 500
    $focused = [Windows.Automation.AutomationElement]::FocusedElement
    if ($focused.Current.ProcessId -ne $session.Process.Id -or $focused.Current.Name -ne 'Address:') {
        throw "the Address box did not get the keyboard focus (focus is on '$($focused.Current.Name)' in process $($focused.Current.ProcessId))"
    }
    [Windows.Forms.SendKeys]::SendWait('^a')
    [Windows.Forms.SendKeys]::SendWait($Keys)
    Start-Sleep -Milliseconds 300
    [Windows.Forms.SendKeys]::SendWait('{ENTER}')
    Start-Sleep -Seconds 2
    $Edit.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
}

# The "Address:" box of the Memory 1 or the Disassembly window, shown first.
function Get-AddressBox([string]$Command, [string]$WindowName) {
    $dte.ExecuteCommand($Command)
    $deadline = (Get-Date).AddSeconds(30)
    do {
        Start-Sleep -Seconds 1
        $main = Get-VsMainWindow $session.Process.Id
        $editType = New-UiCondition $UiElement::ControlTypeProperty ([Windows.Automation.ControlType]::Edit)
        foreach ($e in $main.FindAll($UiScope::Descendants, $editType)) {
            if ($e.Current.Name -ne 'Address:') { continue }
            # Both windows have an Address box: take the one inside the wanted window.
            $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
            for ($p = $walker.GetParent($e); $p; $p = $walker.GetParent($p)) {
                if ($p.Current.Name -like "$WindowName*") { return $e }
            }
        }
    } while ((Get-Date) -lt $deadline)
    throw "the Address box of the $WindowName window was not found"
}

# The leading "0x..." of a pointer value as a number.
function Get-Address([string]$Expression) {
    $value = $dbg.GetExpression($Expression, $true, 5000).Value
    if ($value -notmatch '^0x([0-9a-fA-F]+)') { throw "$Expression is not an address: $value" }
    [Convert]::ToUInt64($Matches[1], 16)
}

# Waits until the debugger stops and prints where.
function Wait-Break([string]$What) {
    Wait-Until { $dbg.CurrentMode -eq 2 } 120 $What
    $hit = try { $dbg.BreakpointLastHit.Name } catch { '' }
    "  stopped in $($dbg.CurrentStackFrame.FunctionName) (reason $($dbg.LastBreakReason), breakpoint '$hit')"
}

$dbg.Go($false)
$watcher = $null
try {
    if (-not $CSharp) {
        Wait-Break 'the BREAK_ADDR breakpoint'
        $watcher = Start-DialogWatcher $session.Process.Id
        '===== Expressions that hold addresses ====='
        foreach ($e in 'addr', 'code', '&g_counter', '&local') { '  {0,-10} = {1}' -f $e, $dbg.GetExpression($e, $true, 5000).Value }
        $counterAddress = Get-Address '&g_counter'
        $localAddress = Get-Address '&local'
        Assert-Value 'addr (an integer)' $dbg.GetExpression('addr', $true, 5000).Value ('{0} (0x{0:x16})' -f $counterAddress)

        '===== Data breakpoints by expression ====='
        $null = $dbg.Breakpoints.Add('', '', 1, 1, '', 1, 'C++', 'addr', 4)
        $null = $dbg.Breakpoints.Add('', '', 1, 1, '', 1, 'C++', '&local', 4)
        $data = @($dbg.Breakpoints | Where-Object { $_.LocationType -eq 4 } | ForEach-Object { $_.Name })
        "  data breakpoints: $($data -join '; ')"
        foreach ($address in $counterAddress, $localAddress) {
            $hexAddress = '0x{0:X16}' -f $address
            Assert-True "a data breakpoint on $hexAddress exists" (@($data | Where-Object { $_ -match $hexAddress }).Count -eq 1)
        }

        '===== Breakpoint at the address of twice() ====='
        $twiceAddress = $dbg.GetExpression('code,x', $true, 5000).Value
        $null = $dbg.Breakpoints.Add('', '', 1, 1, '', 1, '', '', 1, $twiceAddress)
        $bound = @($dbg.Breakpoints | Where-Object { $_.LocationType -eq 5 } | ForEach-Object { @($_.Children) })
        Assert-True "the breakpoint at $twiceAddress is bound to twice()" ($bound.Count -eq 1 -and $bound[0].FunctionName -match 'twice')

        '===== Memory window at addr ====='
        $box = Set-AddressBox (Get-AddressBox 'Debug.Memory1' 'Memory 1') 'addr'
        Assert-Value 'Memory 1 address box' $box ('0x{0:X16}' -f $counterAddress)

        '===== Disassembly window at code+2 ====='
        $box = Set-AddressBox (Get-AddressBox 'Debug.Disassembly' 'Disassembly') 'code{+}2'
        Assert-Value 'Disassembly address box' $box 'twice(int)'

        '===== The breakpoints stop the program ====='
        $dbg.Go($false)
        Wait-Break 'the breakpoint in twice()'
        Assert-True "stopped in twice() (at $($dbg.CurrentStackFrame.FunctionName))" ($dbg.CurrentStackFrame.FunctionName -match 'twice')
        $dbg.Go($false)
        Wait-Break 'the data breakpoint on g_counter'
        Assert-Value 'g_counter at the data breakpoint' $dbg.GetExpression('g_counter', $true, 5000).Value '6 (0x00000006)'
        # The data breakpoint on a local would be disabled with a message when its function returns.
        foreach ($bp in @($dbg.Breakpoints)) { if ($bp.LocationType -in 4, 5) { $bp.Delete() } }
        $dbg.Go($false)
    }

    '===== Conditional breakpoint i == 0x10 ====='
    Wait-Break 'the conditional breakpoint'
    if (-not $watcher) { $watcher = Start-DialogWatcher $session.Process.Id }
    Assert-Value 'i' $dbg.GetExpression('i', $true, 5000).Value '16 (0x00000010)'
    Assert-Value 'sum' $dbg.GetExpression('sum', $true, 5000).Value '120 (0x00000078)'

    '===== Tracepoint output ====='
    $lines = @((Get-DebugOutput) -split "`r?`n" | Where-Object { $_ -match '^TP ' })
    foreach ($l in $lines) { "  output: $l" }
    Assert-True "the tracepoint wrote '$traceLine' once" (@($lines | Where-Object { $_.Trim() -ceq $traceLine }).Count -eq 1)
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message) (debugger mode $($dbg.CurrentMode))"
    $script:failures++
} finally {
    if ($watcher) { $messages = Stop-DialogWatcher $watcher }
}
foreach ($m in $messages) { Assert-True 'no error message box' $false "- Visual Studio showed: $m" }

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

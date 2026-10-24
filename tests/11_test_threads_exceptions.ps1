# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Switching stack frames and threads, and stopping at exceptions (TestCpp\main.cpp,
# TestCSharp\Program.cs). Values must show both radixes in every frame and thread:
#   - BREAK_ADD: arguments of add(), then the caller's frame (main: a = 100).
#   - BREAK_WORKER on a second thread: worker's argument, then the main thread's frames
#     (threads(): before = 0x55, main: a = 100).
#   - Thrown exception (Visual Studio set to break when TestError / InvalidOperationException is
#     thrown): the throwing function's locals, and for C# $exception.
#   - BREAK_CATCH: the caught exception object.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\11_test_threads_exceptions.ps1 [-Vs 2026] [-CSharp]
#
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
Use-Vs $Vs
"===== $($VsInfo.Name), $(if ($CSharp) { 'C#' } else { 'C++' }) ====="

# The exception settings (Debugger3.ExceptionGroups) are not reachable through PowerShell's late
# binding; the typed interfaces are used through reflection.
$envdte90 = [Reflection.Assembly]::LoadFrom((Join-Path $VsInfo.Root 'Common7\IDE\PublicAssemblies\envdte90.dll'))
$settingsType = $envdte90.GetType('EnvDTE90.ExceptionSettings')

$target = Get-TestTarget -CSharp:$CSharp
if ($CSharp) {
    $fn = @{ Add = 'Program.Add'; Main = 'Program.Main'; Worker = 'Program.Worker'; Threads = 'Program.Threads'; Thrower = 'Program.Exceptions' }
    $exceptionGroup = 'Common Language Runtime Exceptions'
    $exceptionType = 'System.InvalidOperationException'
    # HResult of InvalidOperationException: COR_E_INVALIDOPERATION.
    $atThrow = @{ 'code' = '4660 (0x00001234)'; '$exception.HResult' = '-2146233079 (0x80131509)' }
    $atCatch = @{ 'e.HResult' = '-2146233079 (0x80131509)'; 'e.Message' = '"boom"'; 'code' = '4660 (0x00001234)' }
} else {
    $fn = @{ Add = 'add'; Main = 'main'; Worker = 'worker'; Threads = 'threads'; Thrower = 'exceptions' }
    $exceptionGroup = 'C++ Exceptions'
    $exceptionType = 'TestError'
    $atThrow = @{ 'code' = '4660 (0x00001234)' }
    $atCatch = @{ 'e.code' = '4660 (0x00001234)'; 'e' = '{code=4660 (0x00001234) }' }
}

$session = Start-ExpVs $target.Exe
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
foreach ($marker in 'BREAK_ADD', 'BREAK_WORKER', 'BREAK_CATCH') {
    $null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source $marker))
}
$dbg.HexDisplayMode = $false

# Waits until the debugger stops and prints where.
function Wait-Break([string]$What) {
    Wait-Until { $dbg.CurrentMode -eq 2 } 120 $What
    "  stopped in $($dbg.CurrentStackFrame.FunctionName) (thread $($dbg.CurrentThread.ID), reason $($dbg.LastBreakReason))"
}

# Makes the frame of $Function on $Thread (default: the current thread) the current frame.
function Select-Frame([string]$Function, $Thread = $dbg.CurrentThread) {
    if ($Thread.ID -ne $dbg.CurrentThread.ID) { $dbg.CurrentThread = $Thread }
    if ($dbg.CurrentStackFrame.FunctionName -eq $Function) { return }
    # Visual Studio 2026 shows a "[Waiting on Thread ...]" line on a thread that waits for
    # another one and folds non-user frames into "[External Code]"; setting CurrentStackFrame
    # then selects the line at the same position of that shorter list, not the given frame (and
    # fails beyond its end). So the frames are tried until the wanted function is the current one.
    # Lines in brackets are skipped: "[Waiting on Thread ...]" switches to the other thread.
    foreach ($f in @($dbg.CurrentThread.StackFrames)) {
        if ($f.FunctionName.StartsWith('[')) { continue }
        try { $dbg.CurrentStackFrame = $f } catch { continue }
        if ($dbg.CurrentThread.ID -ne $Thread.ID) { $dbg.CurrentThread = $Thread }
        if ($dbg.CurrentStackFrame.FunctionName -eq $Function) { return }
    }
    throw "could not switch to the frame of $Function on thread $($Thread.ID)"
}

function Get-Local([string]$Name) {
    foreach ($v in $dbg.CurrentStackFrame.Locals) { if ($v.Name -eq $Name) { return $v.Value } }
}

# "100 (0x00000064)" in decimal mode, "0x00000064 (100)" in hex mode.
function Dual([long]$Value) {
    $h = '0x' + $Value.ToString('x8')
    if ($dbg.HexDisplayMode) { "$h ($Value)" } else { "$Value ($h)" }
}

function Assert-Expressions([hashtable]$Expected) {
    foreach ($e in ($Expected.Keys | Sort-Object)) {
        Assert-Value $e $dbg.GetExpression($e, $true, 5000).Value $Expected[$e]
    }
}

$breakOnThrow = $null
$createdException = $false
$watcher = Start-DialogWatcher $session.Process.Id
try {
    $dbg.Go($false)
    Wait-Break 'the BREAK_ADD breakpoint'
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== HexDisplayMode = $hex : frames ====="
        Select-Frame $fn.Add
        Assert-Value "lhs in $($fn.Add)" $dbg.GetExpression('lhs', $true, 5000).Value (Dual 100)
        Select-Frame $fn.Main
        Assert-Value "a in the caller $($fn.Main)" $dbg.GetExpression('a', $true, 5000).Value (Dual 100)
        Assert-Value "a in the caller's Locals" (Get-Local 'a') (Dual 100)
        Select-Frame $fn.Add
        Assert-Value "lhs in $($fn.Add) again" (Get-Local 'lhs') (Dual 100)
    }
    $dbg.HexDisplayMode = $false

    $dbg.Go($false)
    Wait-Break 'the BREAK_WORKER breakpoint'
    $workerThread = $dbg.CurrentThread
    $mainThread = $null
    foreach ($t in $dbg.CurrentProgram.Threads) {
        foreach ($f in $t.StackFrames) { if ($f.FunctionName -eq $fn.Threads) { $mainThread = $t } }
    }
    if (-not $mainThread) { throw "no thread is in $($fn.Threads)" }
    Assert-True "worker runs on its own thread ($($workerThread.ID), main thread $($mainThread.ID))" ($workerThread.ID -ne $mainThread.ID)
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== HexDisplayMode = $hex : threads ====="
        Select-Frame $fn.Worker $workerThread
        Assert-Value "n on the worker thread" $dbg.GetExpression('n', $true, 5000).Value (Dual 0x77)
        Assert-Value "doubled in the worker's Locals" (Get-Local 'doubled') (Dual 0xee)
        Select-Frame $fn.Threads $mainThread
        Assert-Value "before on the main thread" $dbg.GetExpression('before', $true, 5000).Value (Dual 0x55)
        Assert-Value "result in the main thread's Locals" (Get-Local 'result') (Dual 0)
        Select-Frame $fn.Main $mainThread
        Assert-Value "a in main on the main thread" $dbg.GetExpression('a', $true, 5000).Value (Dual 100)
    }
    $dbg.HexDisplayMode = $false
    Select-Frame $fn.Worker $workerThread

    "===== Break when $exceptionType is thrown ====="
    $groups = $envdte90.GetType('EnvDTE90.Debugger3').GetProperty('ExceptionGroups').GetValue($dbg)
    $group = $envdte90.GetType('EnvDTE90.ExceptionGroups').GetMethod('Item').Invoke($groups, @($exceptionGroup))
    try {
        $breakOnThrow = $settingsType.GetMethod('Item').Invoke($group, @($exceptionType))
    } catch {
        $breakOnThrow = $settingsType.GetMethod('NewException').Invoke($group, @($exceptionType, [uint32]0))
        $createdException = $true
    }
    $settingsType.GetMethod('SetBreakWhenThrown').Invoke($group, @($true, $breakOnThrow))
    $dbg.Go($false)
    Wait-Break "the thrown $exceptionType"
    Select-Frame $fn.Thrower
    Assert-Expressions $atThrow
    if ($CSharp) { "  `$exception = $($dbg.GetExpression('$exception', $true, 5000).Value)" }
    $settingsType.GetMethod('SetBreakWhenThrown').Invoke($group, @($false, $breakOnThrow))

    '===== Caught exception ====='
    $dbg.Go($false)
    Wait-Break 'the BREAK_CATCH breakpoint'
    Assert-Expressions $atCatch

    $session.Process.Refresh()
    Assert-True 'Visual Studio still responds' $session.Process.Responding
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message) (debugger mode $($dbg.CurrentMode), script line $($_.InvocationInfo.ScriptLineNumber))"
    $script:failures++
} finally {
    # Exception settings are kept by Visual Studio: restore them.
    if ($breakOnThrow) {
        try { $settingsType.GetMethod('SetBreakWhenThrown').Invoke($group, @($false, $breakOnThrow)) } catch { }
        if ($createdException) { try { $settingsType.GetMethod('Remove').Invoke($group, @($exceptionType)) } catch { } }
    }
    $messages = Stop-DialogWatcher $watcher
}
foreach ($m in $messages) { Assert-True 'no error message box' $false "- Visual Studio showed: $m" }

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

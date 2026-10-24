# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Mixed-mode debugging: TestMixed.exe (C#) calls native_add() in TestNative.dll (C++). The test
# starts the program and attaches the native and the managed debugger to it at the same time.
# Both languages must show both radixes in the same debug session:
#   - BREAK_MANAGED in Program.Main (C#),
#   - BREAK_NATIVE in native_add (C++), then the managed caller's frame.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\13_test_mixed_mode.ps1 [-Vs 2026]
#
# -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 400
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name), mixed mode (C# and C++) ====="

# Attaching with two debug engines needs Debugger2/Process2.Attach2, which PowerShell's late
# binding cannot reach; a small typed helper does it (the EnvDTE80 types live in
# Microsoft.VisualStudio.Interop.dll).
$interop = Join-Path $VsInfo.Root 'Common7\IDE\PublicAssemblies\Microsoft.VisualStudio.Interop.dll'
Add-Type -Path $interop
Add-Type -ReferencedAssemblies $interop -TypeDefinition @'
using System;
using System.Collections.Generic;

public static class MixedAttach
{
    // Attaches the debug engines whose names start with the given prefixes to process pid and
    // returns their names.
    public static string Attach(object debugger, int pid, string[] enginePrefixes)
    {
        var dbg = (EnvDTE80.Debugger2)debugger;
        var engines = new List<EnvDTE80.Engine>();
        foreach (string prefix in enginePrefixes)
        {
            foreach (EnvDTE80.Engine e in dbg.Transports.Item("Default").Engines)
            {
                if (e.Name.StartsWith(prefix, StringComparison.Ordinal)) { engines.Add(e); break; }
            }
        }
        if (engines.Count != enginePrefixes.Length) throw new InvalidOperationException("debug engine not found");
        foreach (EnvDTE80.Process2 p in dbg.LocalProcesses)
        {
            if (p.ProcessID == pid)
            {
                p.Attach2(engines.ToArray());
                return string.Join(", ", engines.ConvertAll(e => e.Name));
            }
        }
        throw new InvalidOperationException("process " + pid + " not found");
    }
}
'@

$target = Get-TestTarget -Mixed
$session = Start-ExpVs $target.Exe
$program = $null
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$dbg = $session.Dte.Debugger
$null = $dbg.Breakpoints.Add('', $target.Source, (Get-MarkerLine $target.Source 'BREAK_MANAGED'))
$null = $dbg.Breakpoints.Add('', $target.NativeSource, (Get-MarkerLine $target.NativeSource 'BREAK_NATIVE'))
$dbg.HexDisplayMode = $false

# "100 (0x00000064)" in decimal mode, "0x00000064 (100)" in hex mode.
function Dual([long]$Value) {
    $h = '0x' + $Value.ToString('x8')
    if ($dbg.HexDisplayMode) { "$h ($Value)" } else { "$Value ($h)" }
}

function Wait-Break([string]$What) {
    Wait-Until { $dbg.CurrentMode -eq 2 } 120 $What
    "  stopped in $($dbg.CurrentStackFrame.FunctionName) ($($dbg.CurrentStackFrame.Language))"
}

$watcher = Start-DialogWatcher $session.Process.Id
try {
    # The program waits until a debugger is attached.
    $program = Start-Process $target.Exe -PassThru -WindowStyle Minimized
    Wait-Until { @($dbg.LocalProcesses | Where-Object { $_.ProcessID -eq $program.Id }).Count -eq 1 } 30 'TestMixed.exe in the process list'
    $prefixes = [string[]]@('Native', 'Managed (.NET Framework 4')
    "  attached with: $([MixedAttach]::Attach($dbg, $program.Id, $prefixes))"

    Wait-Break 'the BREAK_MANAGED breakpoint'
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== HexDisplayMode = $hex : C# ====="
        Assert-Value 'a (C#)' $dbg.GetExpression('a', $true, 5000).Value (Dual 100)
        Assert-Value 's (C#)' $dbg.GetExpression('s', $true, 5000).Value $(if ($hex) { '0xffffffd6 (-42)' } else { '-42 (0xffd6)' })
    }
    $dbg.HexDisplayMode = $false

    $dbg.Go($false)
    Wait-Break 'the BREAK_NATIVE breakpoint'
    "  call stack: $((@($dbg.CurrentThread.StackFrames) | ForEach-Object { $_.FunctionName }) -join ' <- ')"
    foreach ($hex in $false, $true) {
        $dbg.HexDisplayMode = $hex
        "===== HexDisplayMode = $hex : C++ and its C# caller ====="
        $dbg.CurrentStackFrame = @($dbg.CurrentThread.StackFrames)[0]
        Assert-Value 'lhs (C++)' $dbg.GetExpression('lhs', $true, 5000).Value (Dual 100)
        Assert-Value 'rhs (C++)' $dbg.GetExpression('rhs', $true, 5000).Value $(if ($hex) { '0xffd6 (-42)' } else { '-42 (0xffd6)' })
        Assert-Value 'sum (C++)' $dbg.GetExpression('sum', $true, 5000).Value (Dual 58)
        $caller = @($dbg.CurrentThread.StackFrames | Where-Object { $_.FunctionName -eq 'Program.Main' })
        if (-not $caller) { throw 'the managed caller Program.Main is not on the call stack' }
        $dbg.CurrentStackFrame = $caller[0]
        Assert-Value 'a in the C# caller' $dbg.GetExpression('a', $true, 5000).Value (Dual 100)
    }
    $dbg.HexDisplayMode = $false

    $session.Process.Refresh()
    Assert-True 'Visual Studio still responds' $session.Process.Responding
} catch {
    # An unexpected error is a failed check; Visual Studio is still closed below.
    "  CHECK FAIL  $($_.Exception.Message) (debugger mode $($dbg.CurrentMode))"
    $script:failures++
} finally {
    $messages = Stop-DialogWatcher $watcher
}
foreach ($m in $messages) { Assert-True 'no error message box' $false "- Visual Studio showed: $m" }

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
    if ($program) { Stop-Process -Id $program.Id -Force -ErrorAction SilentlyContinue }
}
Exit-WithResult

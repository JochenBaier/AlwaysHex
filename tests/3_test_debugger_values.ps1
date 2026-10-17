# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Automated debugger check. Starts the experimental Visual Studio instance (with AlwaysHex
# installed by 1_install_in_experimental_vs.ps1), debugs the C++ test program (or the C# one with -CSharp),
# stops at the BREAK_* markers and prints what the debugger shows: Watch-style evaluation,
# Locals, struct/array members, function arguments and value editing, with hex display off
# and on. Every integer value should appear in both radixes, e.g. "100 (0x00000064)".
# Selected values are checked ("CHECK ok" / "CHECK FAIL"); any failure ends with exit code 1.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\3_test_debugger_values.ps1 [-Vs 2026] [-CSharp] [-Quick]
#
# -Quick only evaluates two variables. -KeepOpen leaves Visual Studio running afterwards.
param(
    [switch]$CSharp,
    [switch]$Quick,
    [switch]$KeepOpen,
    [ValidateSet('2022', '2026')][string]$Vs = '2022',
    [int]$WatchdogSec = 180
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
Use-Vs $Vs
"===== $($VsInfo.Name) ====="

$target = Get-TestTarget -CSharp:$CSharp
$exe = $target.Exe
$src = $target.Source
if ($CSharp) {
    $quickList = 'a', 'b8'
    $all = 'a','neg','u','s','us','ll','ull','b8','sb','ch','flag','f','d','money','arr','col','acc','pt','h','str','ip',
           'a+1','pt.Y','arr[1]','h.Field','h.Prop','a,h','a,d'
    $members = 'pt', 'arr', 'h'
    # Values that must appear exactly like this (TestCSharp\Program.cs), per hex display mode.
    $expected = @{
        'dec' = @{ 'a' = '100 (0x00000064)'; 'neg' = '-1 (0xffffffff)'; 's' = '-42 (0xffd6)'; 'ch' = "97 (0x0061) 'a'"
                   'pt.Y' = '300 (0x012c)'; 'h.Prop' = '-2 (0xfffffffffffffffe)'; 'a,h' = '0x00000064' }
        'hex' = @{ 'a' = '0x00000064 (100)'; 'neg' = '0xffffffff (-1)'; 's' = '0xffffffd6 (-42)'; 'ch' = "0x0061 (97) 'a'"
                   'pt.Y' = '0x012c (300)'; 'h.Prop' = '0xfffffffffffffffe (-2)'; 'a,d' = '100' }
    }
} else {
    $quickList = 'a', 'uc'
    $all = 'a','neg','u','s','us','l','ll','ull','ch','uc','sc','wc','c16','c32','b','f','d','p','arr','u8','i','i32','sz',
           'col','m','pt','str','a+1','pt.y','arr[1]','a,x','a,d'
    $members = 'pt', 'arr'
    # Values that must appear exactly like this (TestCpp\main.cpp), per hex display mode.
    $expected = @{
        'dec' = @{ 'a' = '100 (0x00000064)'; 'neg' = '-1 (0xffffffff)'; 'i' = '42 (0x002a)'; 'ch' = "97 (0x61) 'a'"
                   'col' = 'Blue (200 | 0x000000c8)'; 'pt.y' = '300 (0x012c)'; 'a,x' = '0x00000064' }
        'hex' = @{ 'a' = '0x00000064 (100)'; 'neg' = '0xffffffff (-1)'; 'i' = '0x002a (42)'; 'ch' = "0x61 (97) 'a'"
                   'col' = 'Blue (0x000000c8 | 200)'; 'pt.y' = '0x012c (300)'; 'a,d' = '100' }
    }
}

# Checks: every mismatch is printed as "CHECK FAIL" and makes the script exit with code 1.
$script:failures = 0
function Assert-Value([string]$What, [string]$Actual, [string]$Expected) {
    if ($Actual -ceq $Expected) {
        "  CHECK ok    $What = $Actual"
    } else {
        "  CHECK FAIL  $What = '$Actual', expected '$Expected'"
        $script:failures++
    }
}

# Prints the expressions and remembers their values in $script:values for the checks.
function Show-Expressions($dte, [string[]]$Expressions) {
    $script:values = @{}
    foreach ($e in $Expressions) {
        $r = $dte.Debugger.GetExpression($e, $true, 5000)
        $script:values[$e] = $r.Value
        '  {0,-10} = {1,-36} [{2}]' -f $e, $r.Value, $r.Type
    }
}

# Checks the values remembered by the last Show-Expressions call.
function Assert-Expressions([hashtable]$Expected) {
    foreach ($e in ($Expected.Keys | Sort-Object)) {
        Assert-Value $e $script:values[$e] $Expected[$e]
    }
}

# Checks one local variable of the current stack frame.
function Assert-Local($frame, [string]$Name, [string]$Expected) {
    $value = $null
    foreach ($v in $frame.Locals) { if ($v.Name -eq $Name) { $value = $v.Value } }
    Assert-Value "$Name (Locals)" $value $Expected
}

function Exit-WithResult {
    if ($script:failures) {
        "===== $($script:failures) CHECK(S) FAILED ====="
        exit 1
    }
    '===== all checks passed ====='
}

function Show-Members($dte, [string]$Expression) {
    $r = $dte.Debugger.GetExpression($Expression, $true, 5000)
    "  children of ${Expression}:"
    foreach ($m in $r.DataMembers) { '    {0,-8} = {1}' -f $m.Name, $m.Value }
}

function Show-Locals($frame, [string]$Title, [string]$Property = 'Locals') {
    "  ${Title}:"
    foreach ($v in $frame.$Property) { '    {0,-8} = {1}' -f $v.Name, $v.Value }
}

$session = Start-ExpVs $exe
$proc = $session.Process
$dte = $session.Dte
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile -Command Start-Sleep -Seconds $WatchdogSec; Stop-Process -Id $($proc.Id) -Force -ErrorAction SilentlyContinue"
}

$dbg = $dte.Debugger
$null = $dbg.Breakpoints.Add('', $src, (Get-MarkerLine $src 'BREAK_MAIN'))
$null = $dbg.Breakpoints.Add('', $src, (Get-MarkerLine $src 'BREAK_ADD'))

$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 } 120 'the BREAK_MAIN breakpoint'

if ($Quick) {
    $dbg.HexDisplayMode = $false
    Show-Expressions $dte $quickList
    Assert-Expressions @{ 'a' = $expected['dec']['a'] }
    if (-not $KeepOpen) { Stop-ExpVsSession $session }
    Exit-WithResult
    return
}

foreach ($hex in $false, $true) {
    $dbg.HexDisplayMode = $hex
    "===== HexDisplayMode = $hex : evaluate (Watch / DataTip path) ====="
    Show-Expressions $dte $all
    foreach ($m in $members) { Show-Members $dte $m }
    Show-Locals $dbg.CurrentStackFrame 'Locals window (GetFrameLocals)'
    Assert-Expressions $expected[$(if ($hex) { 'hex' } else { 'dec' })]
    Assert-Local $dbg.CurrentStackFrame 'a' $expected[$(if ($hex) { 'hex' } else { 'dec' })]['a']
}

$dbg.HexDisplayMode = $false
'===== Edit value through a merged result ====='
$e = $dbg.GetExpression('a', $false, 5000)
"  before : $($e.Value)"
$e.Value = '42'
$after = $dbg.GetExpression('a', $true, 5000).Value
"  after  : $after"
Assert-Value 'a after editing to 42' $after '42 (0x0000002a)'
$dbg.GetExpression('a', $false, 5000).Value = '100'

$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 -and $dbg.CurrentStackFrame.FunctionName -match 'add' } 60 'the BREAK_ADD breakpoint'
foreach ($hex in $false, $true) {
    $dbg.HexDisplayMode = $hex
    "===== HexDisplayMode = $hex : frame add() ====="
    Show-Locals $dbg.CurrentStackFrame 'Arguments (GetFrameArguments)' 'Arguments'
    Show-Locals $dbg.CurrentStackFrame 'Locals'
    Assert-Local $dbg.CurrentStackFrame 'lhs' $(if ($hex) { '0x00000064 (100)' } else { '100 (0x00000064)' })
}
$dbg.HexDisplayMode = $false

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

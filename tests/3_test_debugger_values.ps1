# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Automated debugger check. Starts the experimental Visual Studio instance (with AlwaysHex
# installed by 1_install_in_experimental_vs.ps1), debugs the C++ test program (or the C# one with -CSharp),
# stops at the BREAK_* markers and prints what the debugger shows: Watch-style evaluation,
# Locals, struct/array members, function arguments, format specifiers, special values (minimum
# and maximum values, bit fields, unions, library types, nullable types, DebuggerDisplay) and
# value editing, with hex display off and on. Every integer value should appear in both radixes,
# e.g. "100 (0x00000064)"; values with a format specifier stay as the expression evaluator shows them.
# Also checks that side effects and function calls run exactly once.
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
    [int]$WatchdogSec = 300
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
           'a+1','pt.Y','arr[1]','h.Field','h.Prop','a,h','a,d','a,nq'
    $members = 'pt', 'arr', 'h'
    # Values that must appear exactly like this (TestCSharp\Program.cs), per hex display mode.
    # C#: ",h"/",d" become a radix change before AlwaysHex's formatter sees the value, so they
    # still show both radixes, the requested one first (known limitation, see README).
    $expected = @{
        'dec' = @{ 'a' = '100 (0x00000064)'; 'neg' = '-1 (0xffffffff)'; 's' = '-42 (0xffd6)'; 'ch' = "97 (0x0061) 'a'"
                   'pt.Y' = '300 (0x012c)'; 'h.Prop' = '-2 (0xfffffffffffffffe)'; 'a,h' = '0x00000064 (100)'
                   'a,nq' = '100 (0x00000064)' }
        'hex' = @{ 'a' = '0x00000064 (100)'; 'neg' = '0xffffffff (-1)'; 's' = '0xffffffd6 (-42)'; 'ch' = "0x0061 (97) 'a'"
                   'pt.Y' = '0x012c (300)'; 'h.Prop' = '0xfffffffffffffffe (-2)'; 'a,d' = '100 (0x00000064)' }
    }
    # Special values in SpecialValues(). C#'s own hex display sign-extends sbyte and short.
    $special = 'imin','lmin','umax','s8','ni','nnull','nn','perm','stats','stats.Max','list','list[2]','dict','text','boxed'
    $expectedSpecial = @{
        'dec' = @{ 'imin' = '-2147483648 (0x80000000)'; 'lmin' = '-9223372036854775808 (0x8000000000000000)'
                   'umax' = '18446744073709551615 (0xffffffffffffffff)'; 's8' = '-128 (0x80)'; 'ni' = '5 (0x00000005)'
                   'nnull' = 'null'; 'nn' = '0x0000000000000010'; 'perm' = 'Read | Write'
                   'stats' = 'Count = 3 (0x00000003), Max = 300 (0x0000012c)'; 'list' = 'Count = 3 (0x00000003)'
                   'list[2]' = '300 (0x0000012c)'; 'dict' = 'Count = 2 (0x00000002)'; 'text' = '"hello"'
                   'boxed' = '300 (0x0000012c)' }
        'hex' = @{ 'imin' = '0x80000000 (-2147483648)'; 'lmin' = '0x8000000000000000 (-9223372036854775808)'
                   'umax' = '0xffffffffffffffff (18446744073709551615)'; 's8' = '0xffffff80 (-128)'; 'ni' = '0x00000005 (5)'
                   'nnull' = 'null'; 'nn' = '0x0000000000000010'; 'perm' = 'Read | Write'
                   'stats' = 'Count = 0x00000003 (3), Max = 0x0000012c (300)'; 'list' = 'Count = 0x00000003 (3)'
                   'list[2]' = '0x0000012c (300)'; 'dict' = 'Count = 0x00000002 (2)'; 'text' = '"hello"'
                   'boxed' = '0x0000012c (300)' }
    }
    # Value edits at BREAK_MAIN: expression, new value, value shown afterwards, original value.
    $edits = @(
        @('a', '0x20', '32 (0x00000020)', '100'), @('a', '-5', '-5 (0xfffffffb)', '100'),
        @('pt.X', '77', '77 (0x0000004d)', '10'), @('arr[1]', '0x10', '16 (0x00000010)', '255'),
        @('col', 'Color.Red', 'Red', 'Color.Blue'), @('ch', "'b'", "98 (0x0062) 'b'", "'a'"))
    # Reading a property runs its getter: it must run exactly once.
    $sideEffect = @{ Call = 'cnt.Once'; CallResult = '1 (0x00000001)'; Counter = 'Counter.OnceCalls' }
} else {
    $quickList = 'a', 'uc'
    $all = 'a','neg','u','s','us','l','ll','ull','ch','uc','sc','wc','c16','c32','b','f','d','p','arr','u8','i','i32','sz',
           'col','m','pt','str','a+1','pt.y','arr[1]','a,x','a,d','a,o','a,b','a,c','pt,!','arr,[2]'
    $members = 'pt', 'arr'
    # Values that must appear exactly like this (TestCpp\main.cpp), per hex display mode.
    # Values with a format specifier are left as the C++ expression evaluator shows them.
    $expected = @{
        'dec' = @{ 'a' = '100 (0x00000064)'; 'neg' = '-1 (0xffffffff)'; 'i' = '42 (0x002a)'; 'ch' = "97 (0x61) 'a'"
                   'col' = 'Blue (200 | 0x000000c8)'; 'pt.y' = '300 (0x012c)'; 'a,x' = '0x00000064'
                   'a,o' = '000000000144'; 'a,b' = '0b00000000000000000000000001100100'; 'a,c' = "100 'd'"
                   'pt,!' = "{x=10 y=300 c=113 'q' ...}" }
        'hex' = @{ 'a' = '0x00000064 (100)'; 'neg' = '0xffffffff (-1)'; 'i' = '0x002a (42)'; 'ch' = "0x61 (97) 'a'"
                   'col' = 'Blue (0x000000c8 | 200)'; 'pt.y' = '0x012c (300)'; 'a,d' = '100'
                   'a,o' = '000000000144'; 'a,c' = "0x0064 'd'"; 'pt,!' = "{x=0x0000000a y=0x012c c=0x71 'q' ...}" }
    }
    # Special values in special_values().
    $special = 'imin','llmin','umax','u16','bits','bits.sgn','ov.i','ov.f','fl','ref','hr','hr,hr','text','vec','vec[2]',
               'mp','sp->y','opt'
    $expectedSpecial = @{
        'dec' = @{ 'imin' = '-2147483648 (0x80000000)'; 'llmin' = '-9223372036854775808 (0x8000000000000000)'
                   'umax' = '18446744073709551615 (0xffffffffffffffff)'; 'u16' = '65535 (0xffff)'
                   'bits' = '{lo=5 (0x00000005) mid=17 (0x00000011) sgn=-3 (0xfffffffd) }'; 'bits.sgn' = '-3 (0xfffffffd)'
                   'ov.i' = '1078530011 (0x40490fdb)'; 'ov.f' = '3.14159274'; 'fl' = 'FlagA | FlagC (5 | 0x00000005)'
                   'ref' = '4660 (0x00001234)'; 'hr' = '-2147467259 (0x80004005)'; 'hr,hr' = 'E_FAIL'; 'text' = '"hello"'
                   'vec' = '{ size=3 (0x0000000000000003) }'; 'vec[2]' = '300 (0x0000012c)'
                   'mp' = '{ size=2 (0x0000000000000002) }'; 'sp->y' = '300 (0x012c)'; 'opt' = '42 (0x0000002a)' }
        'hex' = @{ 'imin' = '0x80000000 (-2147483648)'; 'llmin' = '0x8000000000000000 (-9223372036854775808)'
                   'umax' = '0xffffffffffffffff (18446744073709551615)'; 'u16' = '0xffff (65535)'
                   'bits' = '{lo=0x00000005 (5) mid=0x00000011 (17) sgn=0xfffffffd (-3) }'; 'bits.sgn' = '0xfffffffd (-3)'
                   'ov.i' = '0x40490fdb (1078530011)'; 'ov.f' = '3.14159274'; 'fl' = 'FlagA | FlagC (0x00000005 | 5)'
                   'ref' = '0x00001234 (4660)'; 'hr' = '0x80004005 (-2147467259)'; 'hr,hr' = 'E_FAIL'; 'text' = '"hello"'
                   'vec' = '{ size=0x0000000000000003 (3) }'; 'vec[2]' = '0x0000012c (300)'
                   'mp' = '{ size=0x0000000000000002 (2) }'; 'sp->y' = '0x012c (300)'; 'opt' = '0x0000002a (42)' }
    }
    $edits = @(
        @('a', '0x20', '32 (0x00000020)', '100'), @('a', '-5', '-5 (0xfffffffb)', '100'),
        @('pt.x', '77', '77 (0x0000004d)', '10'), @('arr[1]', '0x10', '16 (0x00000010)', '255'),
        @('col', 'Red', 'Red (1 | 0x00000001)', 'Blue'), @('ch', "'b'", "98 (0x62) 'b'", "'a'"))
    # A function call must run exactly once. Its result shows one radix only: the second
    # evaluation never calls functions.
    $sideEffect = @{ Call = 'countCall()'; CallResult = '1'; Counter = 'g_calls' }
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
    Start-ExpVsWatchdog $session $WatchdogSec
}

$dbg = $dte.Debugger
$null = $dbg.Breakpoints.Add('', $src, (Get-MarkerLine $src 'BREAK_MAIN'))
$null = $dbg.Breakpoints.Add('', $src, (Get-MarkerLine $src 'BREAK_ADD'))
$null = $dbg.Breakpoints.Add('', $src, (Get-MarkerLine $src 'BREAK_SPECIAL'))

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

# Hex and negative input, struct members, array elements, enums and characters.
'===== Edit value variants ====='
foreach ($edit in $edits) {
    $dbg.GetExpression($edit[0], $false, 5000).Value = $edit[1]
    Assert-Value "$($edit[0]) after editing to $($edit[1])" $dbg.GetExpression($edit[0], $true, 5000).Value $edit[2]
    $dbg.GetExpression($edit[0], $false, 5000).Value = $edit[3]
}
Assert-Value 'a after restoring' $dbg.GetExpression('a', $true, 5000).Value '100 (0x00000064)'

# The second (other-radix) evaluation must never repeat a side effect: "++a" adds exactly 1.
'===== Side effect runs only once ====='
$null = $dbg.GetExpression('++a', $false, 5000)
$after = $dbg.GetExpression('a', $true, 5000).Value
"  after ++a : $after"
Assert-Value 'a after evaluating ++a once' $after '101 (0x00000065)'
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

$dbg.Go($false)
Wait-Until { $dbg.CurrentMode -eq 2 -and $dbg.CurrentStackFrame.FunctionName -match 'special' } 60 'the BREAK_SPECIAL breakpoint'
foreach ($hex in $false, $true) {
    $dbg.HexDisplayMode = $hex
    "===== HexDisplayMode = $hex : special values ====="
    Show-Expressions $dte $special
    Assert-Expressions $expectedSpecial[$(if ($hex) { 'hex' } else { 'dec' })]
}
$dbg.HexDisplayMode = $false

'===== Function call runs only once ====='
Assert-Value "$($sideEffect.Call) (first call)" $dbg.GetExpression($sideEffect.Call, $true, 5000).Value $sideEffect.CallResult
Assert-Value "$($sideEffect.Counter) after one call" $dbg.GetExpression($sideEffect.Counter, $true, 5000).Value '1 (0x00000001)'

if (-not $KeepOpen) {
    Stop-ExpVsSession $session
}
Exit-WithResult

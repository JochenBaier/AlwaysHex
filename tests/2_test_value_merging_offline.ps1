# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Offline checks of AlwaysHex's string merging: calls the merge functions of the Release build
# directly with example strings. No Visual Studio instance is started.
#   powershell -ExecutionPolicy Bypass -File tests\2_test_value_merging_offline.ps1 [-Vs 2026]
param(
    [ValidateSet('2022', '2026')][string]$Vs = '2022'
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
Use-Vs $Vs
$project = Join-Path $PSScriptRoot '..\AlwaysHex\AlwaysHex.csproj'
& $VsInfo.MSBuild $project -restore -p:Configuration=Release -v:minimal -nologo | Out-Null
if ($LASTEXITCODE) { throw "building $project failed" }

$null = [Reflection.Assembly]::LoadFrom((Join-Path $VsInfo.Root 'Common7\IDE\Microsoft.VisualStudio.Debugger.Engine.dll'))
$asm = [Reflection.Assembly]::LoadFrom((Join-Path $PSScriptRoot '..\AlwaysHex\bin\Release\AlwaysHex.dll'))
$flags = [Reflection.BindingFlags]'NonPublic,Public,Static'

# The functions under test live in different classes (ValueMerger, FrameNameMerger,
# RadixNumbers, CSharpFormatter, FormatSpecifier); find each one by its unique name.
function Get-StaticMethod([string]$Name) {
    $found = @($asm.GetTypes() | ForEach-Object { $_.GetMethod($Name, $flags) } | Where-Object { $_ })
    if ($found.Count -ne 1) { throw "expected exactly one static method '$Name' in AlwaysHex.dll, found $($found.Count)" }
    $found[0]
}

$failures = 0
# $Expected = $null means "left unchanged" (the method returns null).
function Check([string]$Method, [object[]]$Arguments, [object]$Expected) {
    # Reflection needs the raw objects, not PowerShell's PSObject wrappers.
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -is [Management.Automation.PSObject]) { $Arguments[$i] = $Arguments[$i].PSObject.BaseObject }
    }
    $actual = (Get-StaticMethod $Method).Invoke($null, $Arguments)
    if (($null -eq $Expected -and $null -eq $actual) -or ($null -ne $actual -and $actual -ceq $Expected)) {
        "ok    $Method -> $(if ($null -eq $actual) { '(unchanged)' } else { $actual })"
    } else {
        "FAIL  $Method($($Arguments -join ' | ')): expected '$Expected', got '$actual'"
        $script:failures++
    }
}

# Call Stack window frame names (C++ and C#), user radix first.
Check MergeFrameName @("add(int lhs=100, unsigned char rhs=200 'X')", "add(int lhs=0x00000064, unsigned char rhs=0xc8 'X')", $false) `
    "add(int lhs=100 (0x00000064), unsigned char rhs=200 (0xc8) 'X')"
Check MergeFrameName @("add(int lhs=0x00000064, unsigned char rhs=0xc8 'X')", "add(int lhs=100, unsigned char rhs=200 'X')", $true) `
    "add(int lhs=0x00000064 (100), unsigned char rhs=0xc8 (200) 'X')"
Check MergeFrameName @('Program.Add(int lhs = 100, byte rhs = 200)', 'Program.Add(int lhs = 0x00000064, byte rhs = 0xc8)', $false) `
    'Program.Add(int lhs = 100 (0x00000064), byte rhs = 200 (0xc8))'
Check MergeFrameName @('f(int n=-1, double d=1.5000000, int * p=0x000000abcd {5})', 'f(int n=0xffffffff, double d=1.5000000, int * p=0x000000abcd {0x00000005})', $false) `
    'f(int n=-1 (0xffffffff), double d=1.5000000, int * p=0x000000abcd {5})'
Check MergeFrameName @('g(int[3] a=0x0000001234)', 'g(int[0x00000003] a=0x0000001234)', $false) $null
Check MergeFrameName @('main()', 'main()', $false) $null

# Char-literal arguments in C++ frame names take the value Locals shows.
$args1 = New-Object 'System.Collections.Generic.Dictionary[string,string]'
$args1['rhs'] = "200 (0xc8) 'X'"
$args1['w'] = "90 (0x005a) L'Z'"
$args1['lhs'] = '100 (0x00000064)'
Check ReplaceCharArguments @("add(int lhs=100 (0x00000064), unsigned char rhs='X')", $args1) `
    "add(int lhs=100 (0x00000064), unsigned char rhs=200 (0xc8) 'X')"
Check ReplaceCharArguments @("f(wchar_t w=L'Z', unsigned char rhs='X')", $args1) `
    "f(wchar_t w=90 (0x005a) L'Z', unsigned char rhs=200 (0xc8) 'X')"
Check ReplaceCharArguments @("f(unsigned char rhs='Y')", $args1) $null
Check ReplaceCharArguments @("f(const char * s=0x00001234 ""a'b"")", $args1) $null

# Struct summaries: both radixes up to 4 numbers.
Check MergeSummary @('{x=1655 y=222}', '{x=0x00000677 y=0x000000de}', $false) '{x=1655 (0x00000677) y=222 (0x000000de)}'
Check MergeSummary @('{x=0x00000677 y=0x000000de}', '{x=1655 y=222}', $true) '{x=0x00000677 (1655) y=0x000000de (222)}'
Check MergeSummary @("{x=10 y=300 c=113 'q' ...}", "{x=0x0000000a y=0x012c c=0x71 'q' ...}", $false) `
    "{x=10 (0x0000000a) y=300 (0x012c) c=113 (0x71) 'q' ...}"
Check MergeSummary @('0x000000ab {x=5}', '0x000000ab {x=0x00000005}', $false) '0x000000ab {x=5 (0x00000005)}'
Check MergeSummary @('{left=0 top=0 right=1920 bottom=1080}', '{left=0x00000000 top=0x00000000 right=0x00000780 bottom=0x00000438}', $false) `
    '{left=0 (0x00000000) top=0 (0x00000000) right=1920 (0x00000780) bottom=1080 (0x00000438)}'
Check MergeSummary @('{a=1 b=2 c=3 d=4 e=5}', '{a=0x1 b=0x2 c=0x3 d=0x4 e=0x5}', $false) $null
Check MergeSummary @('{msg=0x00000113 wp=0x0000000000006e3a}', '{msg=0x00000113 wp=0x0000000000006e3a}', $false) $null
Check MergeSummary @('{1, 255, 4096}', '{0x00000001, 0x000000ff, 0x00001000}', $false) $null

# Both renderings must be the same value, otherwise nothing is merged.
Check MergeValue @('100', '0x00000065', $false) $null
Check MergeValue @('300', '0xff', $false) $null
Check MergeValue @('-129', '0x7f', $false) $null
Check MergeValue @('-1', '0xffffffff', $false) '-1 (0xffffffff)'
Check MergeValue @('0xffd6', '-42', $true) '0xffd6 (-42)'
Check MergeValue @('-5', '0xfb', $false) '-5 (0xfb)'
Check MergeFrameName @('f(int a=100)', 'f(int a=0x00000065)', $false) $null
Check MergeSummary @('{x=1 y=2}', '{x=0x00000001 y=0x00000003}', $false) $null
Check SameNumber @('18446744073709551615', '0xffffffffffffffff') $true
Check SameNumber @('-9223372036854775808', '0x8000000000000000') $true
Check SameNumber @('9223372036854775808', '0x8000000000000000') $true
Check SameNumber @('-1', '0x7fffffffffffffff') $false

# Format specifiers: a comma outside brackets and literals.
Check HasFormatSpecifier @('a,x') $true
Check HasFormatSpecifier @('f(a, b)') $false
Check HasFormatSpecifier @('s == "x,y"') $false
Check HasFormatSpecifier @('s == "a\",b"') $false
Check HasFormatSpecifier @('s == @"C:\dir\",su') $true
Check HasFormatSpecifier @('s == @"a"",b"') $false
Check HasFormatSpecifier @('s == $@"a,{b}"') $false

# Watch/Locals values (C++: two evaluations).
Check MergeValue @('100', '0x00000064', $false) '100 (0x00000064)'
Check MergeValue @("97 'a'", "0x61 'a'", $false) "97 (0x61) 'a'"
Check MergeValue @('Blue (200)', 'Blue (0x000000c8)', $false) 'Blue (200 | 0x000000c8)'
Check MergeValue @('0x0000001234 {5}', '0x0000001234 {0x00000005}', $false) $null

# C# local formatting.
Check FormatOtherRadix @('-42', 'short', $false) '-42 (0xffd6)'
Check FormatOtherRadix @('0xffffffd6', 'short', $true) '0xffffffd6 (-42)'
Check FormatOtherRadix @("0x0061 'a'", 'char', $true) "0x0061 (97) 'a'"
Check FormatOtherRadix @('18446744073709551615', 'ulong', $false) '18446744073709551615 (0xffffffffffffffff)'
Check FormatOtherRadix @('1.5', 'double', $false) $null

if ($failures) { throw "$failures check(s) failed" }
'all checks passed'

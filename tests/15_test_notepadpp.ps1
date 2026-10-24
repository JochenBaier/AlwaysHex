# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Real-world C++ test: debugs Notepad++ (Debug x64 build of its public source, tag $NppTag) and
# checks AlwaysHex on real code instead of the small test programs, at five breakpoints in different
# parts of Notepad++ (main window, core init, tab bar, editor styles, document buffers), in both display
# modes: integer locals, structs (WNDCLASS, Style, the nppGUI settings) and classes with many members.
#
#   powershell -STA -ExecutionPolicy Bypass -File tests\15_test_notepadpp.ps1 [-Vs 2026] [-NppRoot <folder>]
#
# Notepad++ is looked for in -NppRoot, then $env:ALWAYSHEX_NPP_ROOT, then tests\external\notepad-plus-plus
# (ignored by git). Without its source there, the test downloads tag $NppTag from GitHub (git clone, or
# the release zip without git); without notepad++.exe it builds Debug x64 with the selected Visual
# Studio (several minutes, once). Notepad++ runs with its own settings folder (tests\bin\npp_settings),
# -multiInst and -nosession, so a Notepad++ you have open and your Notepad++ settings are not used.
#
# All five breakpoints are reached during the start of Notepad++, in one debug session, each after the
# prolog of its function where the checked integer locals are initialized (the line numbers belong to
# tag $NppTag; each line's text is checked first). Locals declared further down are not constructed yet
# (random memory): their values are not checked, but every number shown in both radixes must be the
# same number in both. Children are read one by one (DataMembers.Item(i)): enumerating all children of
# a garbage object at once crashes the debugger's worker process in Visual Studio 2022 (a Visual Studio
# bug). The release runner runs this test with Visual Studio 2026 only.
param(
    [ValidateSet('2022', '2026')][string]$Vs = '2026',
    [string]$NppRoot = '',
    [switch]$KeepOpen,
    [int]$WatchdogSec = 900
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
. (Join-Path $PSScriptRoot 'ui_automation_helpers.ps1')
Add-Type -AssemblyName System.Numerics
Use-Vs $Vs

$NppTag = 'v8.9.8.1'
# The breakpoints: source line (its text is checked), the function it is in, integer expressions that
# must show both radixes (Exact: also this decimal value), locals walked two levels deep instead of
# one, and the minimum number of Locals rows with both radixes (about half of what was measured with
# v8.9.8.1 on VS 2026, so that a walk where merging stops fails).
$Locations = @(
    @{ File = 'PowerEditor\src\Notepad_plus_Window.cpp'; Line = 82; Text = 'if (!::RegisterClass(&nppClass))'
       Function = 'Notepad_plus_Window::init'; Ints = @('nppClass.style', 'nppClass.cbClsExtra', 'nppClass.cbWndExtra', 'cmdLineParams->_line2go')
       Exact = @{ 'nppClass.style' = 8200 }; Deep = @('nppClass', 'cmdLineParams'); MinDual = 100 }
    @{ File = 'PowerEditor\src\Notepad_plus.cpp'; Line = 247; Text = 'switch (tabIconSet)'
       Function = 'Notepad_plus::init'; Ints = @('dpi', 'langPos2BeRemoved', 'tabBarStatus', 'tabIconSet', 'indexDocTabIcon', 'nppGUI._tabStatus')
       Exact = @{ 'indexDocTabIcon' = 0 }; Deep = @('nppGUI'); MinDual = 500 }
    @{ File = 'PowerEditor\src\WinControls\TabBar\TabBar.cpp'; Line = 294; Text = 'int vertical = isVertical ? (TCS_VERTICAL | TCS_MULTILINE | TCS_RIGHTJUSTIFY) : 0;'
       Function = 'TabBarPlus::init'; Ints = @('dpi', 'closeOrder', 'pinOder', 'buttonsStatus')
       Exact = @{}; Deep = @(); MinDual = 15 }
    @{ File = 'PowerEditor\src\ScintillaComponent\ScintillaEditView.cpp'; Line = 884; Text = 'if (fontStyle != STYLE_NOT_USED)'
       Function = 'ScintillaEditView::setSpecialStyle'; Ints = @('styleID', 'fontStyle', 'styleToSet._styleID', 'styleToSet._fgColor', 'styleToSet._fontSize')
       Exact = @{}; Deep = @('styleToSet'); MinDual = 20 }
    @{ File = 'PowerEditor\src\ScintillaComponent\Buffer.cpp'; Line = 1774; Text = 'newBuf->_lang = ndds._lang;'
       Function = 'FileManager::bufferFromDocument'; Ints = @('_nbBufs', 'newBuf->_references', 'ndds._codepage')
       Exact = @{ 'ndds._codepage' = -1 }; Deep = @('newBuf', 'ndds'); MinDual = 50 }
)
"===== $($VsInfo.Name), Notepad++ $NppTag ====="

# Returns the Notepad++ folder and exe; downloads and builds as needed, and checks the breakpoint lines.
function Get-NotepadPlusPlus {
    $root = if ($NppRoot) { $NppRoot } elseif ($env:ALWAYSHEX_NPP_ROOT) { $env:ALWAYSHEX_NPP_ROOT } else { Join-Path $PSScriptRoot 'external\notepad-plus-plus' }
    $sln = Join-Path $root 'PowerEditor\visual.net\notepadPlus.sln'
    $exe = Join-Path $root 'PowerEditor\visual.net\x64\Debug\notepad++.exe'
    if (-not (Test-Path $sln)) {
        "Notepad++ source not found in ${root}: downloading $NppTag from GitHub"
        $parent = Split-Path $root -Parent
        $null = New-Item -ItemType Directory -Force $parent
        if (Get-Command git -ErrorAction SilentlyContinue) {
            & git clone --quiet --depth 1 --branch $NppTag https://github.com/notepad-plus-plus/notepad-plus-plus.git $root
            if ($LASTEXITCODE) { throw "git clone of Notepad++ $NppTag failed" }
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $zip = Join-Path $parent "notepad-plus-plus-$NppTag.zip"
            Invoke-WebRequest "https://github.com/notepad-plus-plus/notepad-plus-plus/archive/refs/tags/$NppTag.zip" -OutFile $zip -UseBasicParsing
            Expand-Archive $zip $parent -Force
            Move-Item (Join-Path $parent ('notepad-plus-plus-' + $NppTag.TrimStart('v'))) $root
            Remove-Item $zip
        }
    }
    if (-not (Test-Path $exe)) {
        "building Notepad++ Debug x64 with $($VsInfo.Name) (several minutes) ..."
        & $VsInfo.MSBuild $sln -p:Configuration=Debug -p:Platform=x64 -m -v:minimal -nologo | Write-Host
        if ($LASTEXITCODE -or -not (Test-Path $exe)) { throw "building Notepad++ failed" }
    }
    foreach ($loc in $Locations) {
        $source = Join-Path $root $loc.File
        $text = (Get-Content $source)[$loc.Line - 1].Trim()
        if ($text -ne $loc.Text) { throw "$source line $($loc.Line) is '$text', expected '$($loc.Text)': this test needs Notepad++ $NppTag" }
    }
    [pscustomobject]@{ Root = $root; Exe = $exe }
}

# Every "decimal (hex)" or "hex (decimal)" pair in a text, as [decimal, hex digits] strings. String
# contents are left out: the garbage strings of unconstructed locals may contain anything.
$DecHex = New-Object Regex '(?<![\w.])(-?\d+) \(0x([0-9a-f]+)\)'
$HexDec = New-Object Regex '(?<![\w.])0x([0-9a-f]+) \((-?\d+)\)'
$Quoted = New-Object Regex '(?:L|u8|u|U)?"(?:[^"\\]|\\.)*"'
function Get-Pairs([string]$Text) {
    $Text = $Quoted.Replace($Text, '""')
    foreach ($m in $DecHex.Matches($Text)) { , @($m.Groups[1].Value, $m.Groups[2].Value) }
    foreach ($m in $HexDec.Matches($Text)) { , @($m.Groups[2].Value, $m.Groups[1].Value) }
}

# True when a decimal and a hex number (printed at a width of 4 bits per digit) are the same value;
# negative decimals are two's complement at that width.
function Test-SameNumber([string]$Dec, [string]$Hex) {
    $h = [Numerics.BigInteger]::Parse('0' + $Hex, [Globalization.NumberStyles]::AllowHexSpecifier)
    $d = [Numerics.BigInteger]::Parse($Dec)
    if ($d.Sign -lt 0) { $d = [Numerics.BigInteger]::Add($d, [Numerics.BigInteger]::Pow(2, 4 * $Hex.Length)) }
    $d.Equals($h)
}

$script:rows = 0
$script:dualRows = 0
$script:mismatches = New-Object Collections.ArrayList
# Checks one text: every number pair must agree. Returns $true if it holds a pair.
function Test-Text([string]$Where, [string]$Text) {
    $any = $false
    foreach ($p in @(Get-Pairs $Text)) {
        $any = $true
        if (-not (Test-SameNumber $p[0] $p[1]) -and $script:mismatches.Count -lt 20) {
            [void]$script:mismatches.Add("$Where = '$Text' ($($p[0]) is not 0x$($p[1]))")
        }
    }
    $any
}

# Reads a row and its children down to $Depth levels (one by one, at most $Max children per row).
function Test-Rows($Expr, [string]$Path, [int]$Depth, [int]$Max) {
    $script:rows++
    if (Test-Text $Path $Expr.Value) { $script:dualRows++ }
    if ($Depth -le 0) { return }
    $members = $Expr.DataMembers
    $n = [Math]::Min($members.Count, $Max)
    for ($i = 1; $i -le $n; $i++) {
        $child = $members.Item($i)
        Test-Rows $child "$Path/$($child.Name)" ($Depth - 1) $Max
    }
}

$npp = Get-NotepadPlusPlus
$settings = Join-Path $PSScriptRoot 'bin\npp_settings'
if (Test-Path $settings) { Remove-Item $settings -Recurse -Force }
$null = New-Item -ItemType Directory -Force $settings

$session = Start-ExpVs $npp.Exe 'Exp' "-multiInst -nosession -settingsDir=`"$settings`""
if (-not $KeepOpen) {
    # Watchdog: a hung debugger must not leave a frozen VS behind.
    Start-ExpVsWatchdog $session $WatchdogSec
}
$watcher = Start-DialogWatcher $session.Process.Id
try {
    $dbg = $session.Dte.Debugger
    foreach ($loc in $Locations) { $null = $dbg.Breakpoints.Add('', (Join-Path $npp.Root $loc.File), $loc.Line) }
    $dbg.HexDisplayMode = $false
    $dbg.Go($false)
    $reached = @{}
    $worker = $null
    while ($reached.Count -lt $Locations.Count) {
        try { Wait-Until { $dbg.CurrentMode -eq 2 } 120 'the next breakpoint' } catch { break }
        $function = $dbg.CurrentStackFrame.FunctionName
        $loc = $Locations | Where-Object { $_.Function -eq $function -and -not $reached.ContainsKey($_.Function) } | Select-Object -First 1
        if (-not $loc) { "  stopped in $function (not one of the locations): continuing"; $dbg.Go($false); continue }
        $reached[$loc.Function] = $true
        # Some lines run many times (styles, tab bars): only the first stop is checked.
        foreach ($bp in @($dbg.Breakpoints)) { if ($bp.File -like "*$($loc.File)" -and $bp.FileLine -eq $loc.Line) { $bp.Delete() } }
        if (-not $worker) {
            $worker = @(Get-CimInstance Win32_Process -Filter "Name='msvsmon.exe' AND ParentProcessId=$($session.Process.Id)") |
                ForEach-Object { Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue } | Select-Object -First 1
        }
        "===== $($loc.File):$($loc.Line) in $function ====="

        foreach ($hex in $false, $true) {
            $dbg.HexDisplayMode = $hex
            "  --- HexDisplayMode = $hex"
            # Integer values that are initialized here: both radixes, the same number (and the exact value).
            foreach ($e in $loc.Ints) {
                $v = $dbg.GetExpression($e, $true, 5000).Value
                $pairs = @(Get-Pairs $v)
                Assert-True "$e = $v shows both radixes" ($pairs.Count -ge 1)
                foreach ($p in $pairs) { Assert-True "$e : $($p[0]) and 0x$($p[1]) are the same number" (Test-SameNumber $p[0] $p[1]) }
                if ($loc.Exact.ContainsKey($e) -and $pairs.Count) { Assert-Value "$e (decimal part)" $pairs[0][0] "$($loc.Exact[$e])" }
            }

            # All locals of the frame and their members (the Deep ones two levels down).
            $script:rows = 0; $script:dualRows = 0; $script:mismatches.Clear()
            $sw = [Diagnostics.Stopwatch]::StartNew()
            foreach ($l in @($dbg.CurrentStackFrame.Locals)) {
                $depth = if ($loc.Deep -contains $l.Name) { 2 } else { 1 }
                Test-Rows $l $l.Name $depth 150
            }
            "  read $script:rows Locals rows in $([int]$sw.Elapsed.TotalSeconds) s, $script:dualRows of them with numbers in both radixes"
            foreach ($m in $script:mismatches) { "  mismatch: $m" }
            Assert-True "every number pair in the Locals rows is the same number" ($script:mismatches.Count -eq 0)
            Assert-True "at least $($loc.MinDual) Locals rows show both radixes ($script:dualRows)" ($script:dualRows -ge $loc.MinDual)
            Assert-True "the Locals walk took at most 120 s" ($sw.Elapsed.TotalSeconds -le 120)

            # Call Stack window: every number pair in the frame texts is the same number.
            $frames = @((Get-DebugTree $session 'Call Stack').FindAll($UiScope::Children, (New-UiCondition $UiElement::ClassNameProperty 'TreeGridItem')) |
                Select-Object -First 8 | ForEach-Object { try { Get-RowValue $_ } catch { '' } })
            $script:mismatches.Clear()
            foreach ($f in $frames) { $null = Test-Text 'Call Stack' $f }
            $short = $function -replace '^.*::', ''
            Assert-True "Call Stack shows $function" (@($frames | Where-Object { $_ -match [regex]::Escape($short) }).Count -ge 1)
            Assert-True "every number pair in the Call Stack is the same number" ($script:mismatches.Count -eq 0) "- $($script:mismatches -join '; ')"
        }
        $dbg.HexDisplayMode = $false
        if ($reached.Count -lt $Locations.Count) { $dbg.Go($false) }
    }
    foreach ($loc in $Locations) {
        Assert-True "breakpoint $($loc.File):$($loc.Line) ($($loc.Function)) was reached" $reached.ContainsKey($loc.Function)
    }

    if ($worker) { Assert-True "the debugger's worker process (msvsmon) still runs" (-not $worker.HasExited) }
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

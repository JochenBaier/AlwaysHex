# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Helpers for the tests that need the real debugger windows of the experimental instance
# (scripts 5, 6, 7, 9, 10 and 14), plus the checks and the message box watcher that all newer test
# scripts use. Dot-source after vs_automation_helpers.ps1.
#
# UI Automation (the Windows accessibility interface) is only used to find, select and read
# rows in Locals, Autos, Watch 1 and Call Stack (and the Address boxes in script 9). Commands run
# through DTE. Visual Studio must be visible on an unlocked desktop while these tests run.

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$UiElement = [Windows.Automation.AutomationElement]
$UiScope = [Windows.Automation.TreeScope]

function New-UiCondition($Property, $Value) {
    New-Object Windows.Automation.PropertyCondition($Property, $Value)
}

# The Visual Studio main window. The process can have more top-level windows: a data tip pops
# up when the mouse pointer happens to rest over the code, and Windows may even report it as the
# process's main window. So data tip windows are skipped, and the window titled "... Microsoft
# Visual Studio ..." is preferred. Retried for a while: while Visual Studio is busy, window
# properties can come back empty.
function Get-VsMainWindow([int]$VsPid) {
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $fallback = $null
        try {
            foreach ($w in $UiElement::RootElement.FindAll($UiScope::Children, (New-UiCondition $UiElement::ProcessIdProperty $VsPid))) {
                if ($w.Current.ClassName -like '*DataTip*') { continue }
                if ($w.Current.Name -like '*Microsoft Visual Studio*') { return $w }
                if (-not $fallback -and $w.Current.ClassName -eq 'Window') { $fallback = $w }
            }
        } catch { }
        if ($fallback) { return $fallback }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "the Visual Studio main window of process $VsPid was not found"
}

# The tree control of a debugger tool window ('Locals', 'Autos', 'Watch 1', 'Call Stack'), shown first.
function Get-DebugTree($Session, [ValidateSet('Locals', 'Autos', 'Watch 1', 'Call Stack')][string]$Window) {
    $command = @{ 'Locals' = 'Debug.Locals'; 'Autos' = 'Debug.Autos'; 'Watch 1' = 'Debug.Watch1'; 'Call Stack' = 'Debug.CallStack' }[$Window]
    $main = Get-VsMainWindow $Session.Process.Id
    # Right after the debugger starts, VS can be busy for a while (e.g. opening the Diagnostic
    # Tools window for .NET), so the command is repeated until the window shows up.
    $deadline = (Get-Date).AddSeconds(60)
    $nextCommand = Get-Date
    while ((Get-Date) -lt $deadline) {
        if ((Get-Date) -ge $nextCommand) {
            try { $Session.Dte.ExecuteCommand($command) } catch { }
            $nextCommand = (Get-Date).AddSeconds(5)
        }
        foreach ($t in $main.FindAll($UiScope::Descendants, (New-UiCondition $UiElement::ClassNameProperty 'TreeGrid'))) {
            if ($t.Current.Name -eq $Window) { return $t }
        }
        Start-Sleep -Milliseconds 300
    }
    $seen = @(foreach ($t in $main.FindAll($UiScope::Descendants, (New-UiCondition $UiElement::ClassNameProperty 'TreeGrid'))) { "'$($t.Current.Name)'" }) -join ', '
    throw "the $Window window was not found (main window '$($main.Current.Name)', debugger trees: $seen)"
}

# A row by path ("a", "pt/y"): parents are expanded, and the virtualized tree is scrolled
# until the row exists.
function Find-DebugRow($Tree, [string]$Path) {
    $node = $Tree
    $parts = $Path -split '/'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        $cond = New-Object Windows.Automation.AndCondition(
            (New-UiCondition $UiElement::NameProperty $parts[$i]),
            (New-UiCondition $UiElement::ClassNameProperty 'TreeGridItem'))
        $where = if ($i -eq 0) { $UiScope::Children } else { $UiScope::Descendants }
        $next = $node.FindFirst($where, $cond)
        if (-not $next) {
            $scroll = $Tree.GetCurrentPattern([Windows.Automation.ScrollPattern]::Pattern)
            $scroll.SetScrollPercent([Windows.Automation.ScrollPattern]::NoScroll, 0)
            for ($k = 0; $k -lt 60 -and -not $next; $k++) {
                $scroll.ScrollVertical([Windows.Automation.ScrollAmount]::LargeIncrement)
                Start-Sleep -Milliseconds 300
                $next = $node.FindFirst($where, $cond)
            }
        }
        if (-not $next) { throw "row '$($parts[$i])' of '$Path' not found" }
        $node = $next
        if ($i -lt $parts.Count - 1) {
            $node.GetCurrentPattern([Windows.Automation.ExpandCollapsePattern]::Pattern).Expand()
            Start-Sleep -Seconds 1
        }
    }
    $node
}

# The text a row shows in its Value column (Watch/Locals), or the frame text (Call Stack).
function Get-RowValue($Row) {
    $Row.GetCurrentPattern([Windows.Automation.ValuePattern]::Pattern).Current.Value
}

# Selects a row and runs a context-menu command on it, e.g.
# 'DebuggerContextMenus.AutosWindow.BreakWhenValueChanges' (Locals and Watch share these).
function Invoke-RowCommand($Session, [string]$Window, [string]$Path, [string]$Command) {
    $tree = Get-DebugTree $Session $Window
    $row = Find-DebugRow $tree $Path
    $tree.SetFocus()
    $row.GetCurrentPattern([Windows.Automation.SelectionItemPattern]::Pattern).Select()
    $row.SetFocus()
    Start-Sleep -Milliseconds 500
    $cmd = $Session.Dte.Commands.Item($Command)
    if (-not $cmd.IsAvailable) { throw "$Command is not available on '$Path'" }
    $Session.Dte.ExecuteCommand($Command)
    Start-Sleep -Seconds 1
}

# Closes the Autos window (only while debugging), best effort. Visual Studio saves the window
# layout of the experimental instance, so a window one test opens stays open in the next, and
# Autos evaluates the expressions of the current lines on its own at every stop and refresh,
# property getters included; no check may depend on Autos being closed. Debug.Autos shows the
# window, Window.CloseToolWindow closes the ACTIVE tool window. In VS 2026 Autos can become active
# a moment late, and the close would then hit another window (Watch, Output, ...). So the Autos
# tree gets the keyboard focus (UI Automation; when Visual Studio is not the foreground window,
# Debug.Autos alone leaves the focus in another process), and the close runs only once the focus
# is inside the Autos window; otherwise nothing is closed. (Commands, because the items of
# DTE.Windows have no properties in VS 2026.) VS 2022 keeps the closed window for the next
# session; VS 2026 shows Autos again in the next debug session even after a close that worked.
function Close-AutosWindow($Session) {
    try {
        $tree = Get-DebugTree $Session 'Autos'
        $tree.SetFocus()
        $walker = [Windows.Automation.TreeWalker]::ControlViewWalker
        $deadline = (Get-Date).AddSeconds(5)
        do {
            $e = $UiElement::FocusedElement
            $inAutos = $false
            while ($e -and -not $inAutos) {
                if ($e.Current.ProcessId -ne $Session.Process.Id) { break }
                $inAutos = $e.Current.ClassName -eq 'TreeGrid' -and $e.Current.Name -eq 'Autos'
                $e = $walker.GetParent($e)
            }
            if ($inAutos) {
                $Session.Dte.ExecuteCommand('Window.CloseToolWindow')
                return
            }
            Start-Sleep -Milliseconds 200
        } while ((Get-Date) -lt $deadline)
    } catch { }
}

# Watch 1: remove all entries.
function Clear-Watch($Session) {
    $null = Get-DebugTree $Session 'Watch 1'
    try { $Session.Dte.ExecuteCommand('Edit.SelectAll'); $Session.Dte.ExecuteCommand('Edit.Delete') } catch { }
}

# Watch 1: add each name by selecting it in the source file and running Debug.AddWatch
# (which takes no argument). The names must appear as whole words in the source.
function Add-Watch($Session, [string]$Source, [string[]]$Names) {
    $window = $Session.Dte.ItemOperations.OpenFile($Source)
    foreach ($name in $Names) {
        $window.Activate()
        $selection = $Session.Dte.ActiveDocument.Selection
        $selection.StartOfDocument()
        if (-not $selection.FindText($name, 2 + 4)) { throw "'$name' not found in $Source" }  # whole word, match case
        $Session.Dte.ExecuteCommand('Debug.AddWatch')
    }
}

# A message box in Visual Studio (e.g. "Unable to set data breakpoint") blocks every DTE call
# until it is closed. The watcher runs on its own thread, records the text of each message box
# and closes it with OK. Stop-DialogWatcher returns the recorded texts.
function Start-DialogWatcher([int]$VsPid) {
    $state = [hashtable]::Synchronized(@{ Stop = $false; Messages = New-Object Collections.ArrayList })
    $ps = [powershell]::Create()
    $null = $ps.AddScript({
        param($VsPid, $State)
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        if (-not ('AlwaysHexTest.User32' -as [type])) {
            Add-Type -Namespace AlwaysHexTest -Name User32 -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, uint m, IntPtr w, IntPtr l);'
        }
        $E = [Windows.Automation.AutomationElement]
        $S = [Windows.Automation.TreeScope]
        while (-not $State.Stop) {
            try {
                # Message boxes are children of a Visual Studio top-level window (usually the
                # main window; the process can also have data tip windows).
                $box = $null
                foreach ($w in $E::RootElement.FindAll($S::Children, (New-Object Windows.Automation.PropertyCondition($E::ProcessIdProperty, $VsPid)))) {
                    if (-not $box) { $box = $w.FindFirst($S::Children, (New-Object Windows.Automation.PropertyCondition($E::ClassNameProperty, '#32770'))) }
                }
                if ($box) {
                    $texts = foreach ($t in $box.FindAll($S::Descendants, (New-Object Windows.Automation.PropertyCondition($E::ClassNameProperty, 'Static')))) { $t.Current.Name }
                    [void]$State.Messages.Add((($texts | Where-Object { $_ }) -join ' '))
                    $ok = $box.FindFirst($S::Descendants, (New-Object Windows.Automation.PropertyCondition($E::NameProperty, 'OK')))
                    if ($ok) { [void][AlwaysHexTest.User32]::SendMessage([IntPtr]$ok.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero) }  # BM_CLICK
                }
            } catch { }
            Start-Sleep -Milliseconds 300
        }
    }).AddArgument($VsPid).AddArgument($state)
    [pscustomobject]@{ State = $state; PowerShell = $ps; Handle = $ps.BeginInvoke() }
}

function Stop-DialogWatcher($Watcher) {
    $Watcher.State.Stop = $true
    $null = $Watcher.PowerShell.EndInvoke($Watcher.Handle)
    $Watcher.PowerShell.Dispose()
    @($Watcher.State.Messages)
}

# Checks: every mismatch is printed as "CHECK FAIL"; Exit-WithResult ends with exit code 1.
$script:failures = 0
function Assert-Value([string]$What, [string]$Actual, [string]$Expected) {
    if ($Actual -ceq $Expected) {
        "  CHECK ok    $What = $Actual"
    } else {
        "  CHECK FAIL  $What = '$Actual', expected '$Expected'"
        $script:failures++
    }
}

function Assert-True([string]$What, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) { "  CHECK ok    $What" } else { "  CHECK FAIL  $What $Detail"; $script:failures++ }
}

# Polls $Get until it returns $Expected (or $TimeoutSec passes) and returns the last value.
function Wait-Value([scriptblock]$Get, [string]$Expected, [int]$TimeoutSec = 10) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $value = try { & $Get } catch { "<$($_.Exception.Message)>" }
        if ($value -ceq $Expected) { return $value }
        Start-Sleep -Milliseconds 300
    } while ((Get-Date) -lt $deadline)
    $value
}

function Exit-WithResult {
    if ($script:failures) {
        "===== $($script:failures) CHECK(S) FAILED ====="
        exit 1
    }
    '===== all checks passed ====='
}

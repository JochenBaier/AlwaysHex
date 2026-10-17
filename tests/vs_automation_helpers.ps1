# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Shared helpers for driving the experimental VS instance through DTE.
# Dot-source from Windows PowerShell 5.1 or pwsh running in an STA thread, then call
# Use-Vs to pick the Visual Studio version (VS 2022 is selected by default).

# Selects the Visual Studio installation all helpers below use, found through vswhere:
# '2022' = version 17.x, '2026' = version 18.x (any edition). Sets $VsInfo.
function Use-Vs([ValidateSet('2022', '2026')][string]$Version = '2022') {
    $range = @{ '2022' = '[17.0,18.0)'; '2026' = '[18.0,19.0)' }[$Version]
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $info = @{}
    & $vswhere -version $range -products * -prerelease -latest -format text | ForEach-Object {
        if ($_ -match '^(\w+): (.*)$') { $info[$Matches[1]] = $Matches[2] }
    }
    if (-not $info['installationPath']) { throw "Visual Studio $Version is not installed" }

    $root = $info['installationPath']
    $major = $info['installationVersion'].Split('.')[0]
    $script:VsInfo = [pscustomobject]@{
        Name          = $info['displayName']
        Root          = $root
        Major         = $major
        InstanceId    = $info['instanceId']
        DevEnv        = Join-Path $root 'Common7\IDE\devenv.exe'
        MSBuild       = Join-Path $root 'MSBuild\Current\Bin\MSBuild.exe'
        VsixInstaller = Join-Path $root 'Common7\IDE\VSIXInstaller.exe'
        # Settings and extensions of the experimental instance ("/rootsuffix Exp").
        ExpHive       = Join-Path $env:LOCALAPPDATA "Microsoft\VisualStudio\$major.0_$($info['instanceId'])Exp"
    }
}
Use-Vs '2022'

# devenv processes of the selected Visual Studio that run the experimental instance.
function Get-ExpVsProcess {
    Get-CimInstance Win32_Process -Filter "Name='devenv.exe'" |
        Where-Object { $_.CommandLine -match '/rootsuffix Exp' -and $_.ExecutablePath -like "$($VsInfo.Root)\*" }
}

# Closes the selected Visual Studio's experimental instance (it keeps AlwaysHex.dll locked).
function Stop-ExpVs {
    Get-ExpVsProcess | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force
        Wait-Process -Id $_.ProcessId -Timeout 30 -ErrorAction SilentlyContinue
    }
}

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class Rot
{
    [DllImport("ole32.dll")] static extern int GetRunningObjectTable(int reserved, out IRunningObjectTable rot);
    [DllImport("ole32.dll")] static extern int CreateBindCtx(int reserved, out IBindCtx ctx);

    public static object Find(string displayName)
    {
        IRunningObjectTable rot;
        GetRunningObjectTable(0, out rot);
        IEnumMoniker monikers;
        rot.EnumRunning(out monikers);
        var m = new IMoniker[1];
        while (monikers.Next(1, m, IntPtr.Zero) == 0)
        {
            IBindCtx ctx;
            CreateBindCtx(0, out ctx);
            string name;
            m[0].GetDisplayName(ctx, null, out name);
            if (name == displayName)
            {
                object o;
                rot.GetObject(m[0], out o);
                return o;
            }
        }
        return null;
    }
}

[ComImport, Guid("00000016-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IOleMessageFilter
{
    [PreserveSig] int HandleInComingCall(int callType, IntPtr caller, int tickCount, IntPtr interfaceInfo);
    [PreserveSig] int RetryRejectedCall(IntPtr callee, int tickCount, int rejectType);
    [PreserveSig] int MessagePending(IntPtr callee, int tickCount, int pendingType);
}

// Retries calls that devenv rejects while it is busy (RPC_E_CALL_REJECTED).
public class RetryMessageFilter : IOleMessageFilter
{
    [DllImport("ole32.dll")] static extern int CoRegisterMessageFilter(IOleMessageFilter newFilter, out IOleMessageFilter oldFilter);

    public static void Register()
    {
        IOleMessageFilter old;
        CoRegisterMessageFilter(new RetryMessageFilter(), out old);
    }

    int IOleMessageFilter.HandleInComingCall(int callType, IntPtr caller, int tickCount, IntPtr interfaceInfo) { return 0; }
    int IOleMessageFilter.RetryRejectedCall(IntPtr callee, int tickCount, int rejectType) { return rejectType == 2 ? 200 : -1; }
    int IOleMessageFilter.MessagePending(IntPtr callee, int tickCount, int pendingType) { return 2; }
}
'@
[RetryMessageFilter]::Register()

function Wait-Until([scriptblock]$Condition, [int]$TimeoutSec, [string]$What) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return } } catch { }
        Start-Sleep -Milliseconds 500
    }
    throw "Timed out waiting for $What"
}

# Line number (1-based) of the first non-empty line after the line containing $Marker.
function Get-MarkerLine([string]$Source, [string]$Marker) {
    $lines = Get-Content $Source
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match [regex]::Escape($Marker)) {
            for ($j = $i + 1; $j -lt $lines.Count; $j++) {
                if ($lines[$j].Trim()) { return $j + 1 }
            }
        }
    }
    throw "Marker $Marker not found in $Source"
}

# Builds the C++ (TestCpp) or C# (TestCSharp) test program with the selected Visual Studio
# (incremental: only when something changed) and returns its source file and .exe.
function Get-TestTarget([switch]$CSharp) {
    if ($CSharp) {
        $project = Join-Path $PSScriptRoot 'TestCSharp\TestCSharp.csproj'
        $src = Join-Path $PSScriptRoot 'TestCSharp\Program.cs'
        $exe = Join-Path $PSScriptRoot 'bin\TestCSharp.exe'
        $platform = 'AnyCPU'
    } else {
        $project = Join-Path $PSScriptRoot 'TestCpp\TestCpp.vcxproj'
        $src = Join-Path $PSScriptRoot 'TestCpp\main.cpp'
        $exe = Join-Path $PSScriptRoot 'bin\TestCpp.exe'
        $platform = 'x64'
    }

    & $VsInfo.MSBuild $project -restore -p:Configuration=Debug "-p:Platform=$platform" -v:minimal -nologo | Write-Host
    if ($LASTEXITCODE) { throw "building $project failed" }
    [pscustomobject]@{ Source = $src; Exe = $exe }
}

# Starts devenv /rootsuffix Exp /debugexe <exe> and returns its process and DTE object.
function Start-ExpVs([string]$Exe, [string]$RootSuffix = 'Exp') {
    $proc = Start-Process $VsInfo.DevEnv -ArgumentList "/rootsuffix $RootSuffix /debugexe `"$Exe`"" -PassThru
    # The DTE automation object is registered as "VisualStudio.DTE.<major>.0" (17.0, 18.0).
    $moniker = "!VisualStudio.DTE.$($VsInfo.Major).0:$($proc.Id)"
    Wait-Until { [Rot]::Find($moniker) -ne $null } 180 'DTE in the running object table'
    $dte = [Rot]::Find($moniker)
    Wait-Until { $dte.Solution.Projects.Count -ge 1 } 120 'the /debugexe project'
    [pscustomobject]@{ Process = $proc; Dte = $dte }
}

# Ends a session from Start-ExpVs: stops debugging and closes Visual Studio. The temporary
# /debugexe solution is closed without saving first, otherwise Quit() waits for the "Save changes?"
# dialog. If Visual Studio is still running after $TimeoutSec, the process is ended.
function Stop-ExpVsSession($Session, [int]$TimeoutSec = 30) {
    $dte = $Session.Dte
    try { if ($dte.Debugger.CurrentMode -ne 1) { $dte.Debugger.Stop($true) } } catch { }
    try { $dte.Solution.Close($false) } catch { }
    try { $dte.Quit() } catch { }
    if (-not $Session.Process.WaitForExit($TimeoutSec * 1000)) {
        Stop-Process -Id $Session.Process.Id -Force -ErrorAction SilentlyContinue
    }
}

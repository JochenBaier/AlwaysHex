# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Builds the Release VSIX and installs it into the experimental instance of the chosen Visual
# Studio ("/rootsuffix Exp"), exactly as a user would get it: a previously installed AlwaysHex
# is uninstalled first, then the new package is installed. Your normal Visual Studio settings
# and extensions are not touched. A running experimental instance is closed first.
#
#   powershell -ExecutionPolicy Bypass -File tests\1_install_in_experimental_vs.ps1 [-Vs 2026]
param(
    [ValidateSet('2022', '2026')][string]$Vs = '2022'
)
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'vs_automation_helpers.ps1')
Use-Vs $Vs
"using $($VsInfo.Name) ($($VsInfo.Root))"

$root = Split-Path -Parent $PSScriptRoot
& $VsInfo.MSBuild (Join-Path $root 'AlwaysHex.sln') -restore -p:Configuration=Release -v:minimal -nologo
if ($LASTEXITCODE) { throw "build failed" }
$vsix = Join-Path $root 'vsix\bin\Release\AlwaysHex.vsix'

Stop-ExpVs

# Same id as in vsix\source.extension.vsixmanifest.
$id = ([xml](Get-Content (Join-Path $root 'vsix\source.extension.vsixmanifest'))).PackageManifest.Metadata.Identity.Id

function Invoke-VsixInstaller([string[]]$Arguments) {
    # /instanceIds limits the operation to the selected Visual Studio when several are installed.
    $common = '/quiet', '/rootSuffix:Exp', "/instanceIds:$($VsInfo.InstanceId)", '/logFile:alwayshex_install.log'
    $p = Start-Process $VsInfo.VsixInstaller -Wait -PassThru -ArgumentList ($common + $Arguments)
    $p.ExitCode
}

$installed = Get-ChildItem (Join-Path $VsInfo.ExpHive 'Extensions') -Recurse -Filter AlwaysHex.vsdconfig -ErrorAction SilentlyContinue
if ($installed) {
    $null = Invoke-VsixInstaller @("/uninstall:$id")
}
$code = Invoke-VsixInstaller @("`"$vsix`"")
if ($code) { throw "VSIXInstaller failed with exit code $code, see %TEMP%\alwayshex_install.log" }

# VS 2026 does not always refresh its extension cache after an update and then starts without
# the debugger component. Rebuilding the configuration fixes that.
$p = Start-Process $VsInfo.DevEnv -ArgumentList '/rootsuffix Exp /updateconfiguration' -Wait -PassThru
if ($p.ExitCode) { throw "devenv /updateconfiguration failed with exit code $($p.ExitCode)" }

"installed $vsix into the experimental instance of $($VsInfo.Name)"

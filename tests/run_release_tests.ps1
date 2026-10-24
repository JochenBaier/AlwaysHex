# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Jochen Baier

# Full release test: installs the Release build into the experimental instance and runs every
# test script, for Visual Studio 2022 and/or 2026, then prints a summary with the result and the
# duration of each step. A failing step does not stop the run (except a failed installation,
# which skips the remaining steps of that Visual Studio version). Exit code 1 if any step failed.
#
#   powershell -ExecutionPolicy Bypass -File tests\run_release_tests.ps1 [-Vs 2022|2026|2022,2026] [-Only 8,9]
#
# -Only runs just the steps with these script numbers (the installation is then skipped unless
# 1 is listed). The experimental instance is closed by the installation and by every test, and
# Visual Studio must stay visible on an unlocked desktop while the tests run.
param(
    [string]$Vs = '2022,2026',
    [string]$Only = ''
)
$ErrorActionPreference = 'Stop'

$versions = @($Vs -split '[,; ]+' | Where-Object { $_ })
foreach ($v in $versions) { if ($v -notin '2022', '2026') { throw "unknown Visual Studio version '$v' (use 2022 and/or 2026)" } }
$onlyNumbers = @($Only -split '[,; ]+' | Where-Object { $_ })

# Script, extra arguments; the installation and the offline test do not need an STA thread.
$steps = @(
    @{ Script = '1_install_in_experimental_vs.ps1'; Args = @(); Sta = $false }
    @{ Script = '2_test_value_merging_offline.ps1'; Args = @(); Sta = $false }
    @{ Script = '3_test_debugger_values.ps1'; Args = @() }
    @{ Script = '3_test_debugger_values.ps1'; Args = @('-CSharp') }
    @{ Script = '4_test_debug_restart.ps1'; Args = @() }
    @{ Script = '5_test_result_features.ps1'; Args = @() }
    @{ Script = '5_test_result_features.ps1'; Args = @('-CSharp') }
    @{ Script = '5_test_result_features.ps1'; Args = @('-Hex') }
    @{ Script = '5_test_result_features.ps1'; Args = @('-CSharp', '-Hex') }
    @{ Script = '6_test_hex_toggle_stress.ps1'; Args = @() }
    @{ Script = '6_test_hex_toggle_stress.ps1'; Args = @('-CSharp') }
    @{ Script = '7_test_cppcli_unchanged.ps1'; Args = @() }
    @{ Script = '8_test_large_data.ps1'; Args = @() }
    @{ Script = '8_test_large_data.ps1'; Args = @('-CSharp') }
    @{ Script = '9_test_breakpoints.ps1'; Args = @() }
    @{ Script = '9_test_breakpoints.ps1'; Args = @('-CSharp') }
    @{ Script = '10_test_step_stress.ps1'; Args = @() }
    @{ Script = '10_test_step_stress.ps1'; Args = @('-CSharp') }
    @{ Script = '11_test_threads_exceptions.ps1'; Args = @() }
    @{ Script = '11_test_threads_exceptions.ps1'; Args = @('-CSharp') }
    @{ Script = '12_test_soak.ps1'; Args = @() }
    @{ Script = '12_test_soak.ps1'; Args = @('-CSharp') }
    @{ Script = '13_test_mixed_mode.ps1'; Args = @() }
    @{ Script = '14_test_return_values.ps1'; Args = @() }
    # Real-world code (downloads and builds Notepad++ once); Visual Studio 2026 only.
    @{ Script = '15_test_notepadpp.ps1'; Args = @(); Vs = @('2026') }
)

$results = New-Object Collections.Generic.List[object]
$total = [Diagnostics.Stopwatch]::StartNew()
foreach ($v in $versions) {
    foreach ($step in $steps) {
        $number = $step.Script.Split('_')[0]
        if ($onlyNumbers -and $number -notin $onlyNumbers) { continue }
        if ($step.Vs -and $v -notin $step.Vs) { continue }
        $name = (($step.Script -replace '\.ps1$', ''), ($step.Args -join ' ')) -join ' '
        ''
        "######## Visual Studio $v : $name"
        $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass')
        if ($step.Sta -ne $false) { $arguments += '-STA' }
        $arguments += @('-File', (Join-Path $PSScriptRoot $step.Script), '-Vs', $v) + $step.Args
        $watch = [Diagnostics.Stopwatch]::StartNew()
        & powershell.exe @arguments
        $code = $LASTEXITCODE
        $results.Add([pscustomobject]@{
            VS      = $v
            Step    = $name
            Result  = if ($code -eq 0) { 'passed' } else { "FAILED ($code)" }
            Duration = '{0:m\:ss}' -f $watch.Elapsed
        })
        if ($code -and $number -eq '1') {
            "Installation failed: skipping the other steps for Visual Studio $v."
            break
        }
    }
}

''
'######## Summary'
($results | Format-Table -AutoSize | Out-String).TrimEnd()
$failed = @($results | Where-Object { $_.Result -ne 'passed' }).Count
''
'{0} step(s), {1} failed, {2:h\:mm\:ss} in total' -f $results.Count, $failed, $total.Elapsed
if ($failed) { exit 1 }

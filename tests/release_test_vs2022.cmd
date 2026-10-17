@echo off
rem SPDX-License-Identifier: MIT
rem Copyright (c) 2026 Jochen Baier
rem Full release test of AlwaysHex with Visual Studio 2022 (experimental instance only).
rem Stops at the first failing step. Can be started by double-click.
cd /d "%~dp0.."
powershell -ExecutionPolicy Bypass -File tests\1_install_in_experimental_vs.ps1 || goto failed
powershell -ExecutionPolicy Bypass -File tests\2_test_value_merging_offline.ps1 || goto failed
powershell -STA -ExecutionPolicy Bypass -File tests\3_test_debugger_values.ps1 || goto failed
powershell -STA -ExecutionPolicy Bypass -File tests\3_test_debugger_values.ps1 -CSharp || goto failed
powershell -STA -ExecutionPolicy Bypass -File tests\4_test_debug_restart.ps1 || goto failed
echo.
echo Release test with Visual Studio 2022 finished.
pause
exit /b 0

:failed
echo.
echo Release test with Visual Studio 2022 FAILED (see the output above).
pause
exit /b 1

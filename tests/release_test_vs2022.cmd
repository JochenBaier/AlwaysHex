@echo off
rem SPDX-License-Identifier: MIT
rem Copyright (c) 2026 Jochen Baier
rem Full release test of AlwaysHex with Visual Studio 2022 (experimental instance only):
rem runs every test script through run_release_tests.ps1 and prints a summary at the end.
rem Can be started by double-click.
cd /d "%~dp0.."
powershell -ExecutionPolicy Bypass -File tests\run_release_tests.ps1 -Vs 2022
set result=%errorlevel%
echo.
if %result%==0 (echo Release test with Visual Studio 2022 passed.) else (echo Release test with Visual Studio 2022 FAILED, see the summary above.)
pause
exit /b %result%

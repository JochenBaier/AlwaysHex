# AlwaysHex release tests

The `tests` folder contains two small test programs that are part of the solution,
`TestCpp` (C++) and `TestCSharp` (C#), more that are built only by their test scripts,
`TestCppCli` (C++/CLI) and `TestMixed` with `TestNative` (C# calling a native DLL), plus scripts
that check AlwaysHex in a real Visual Studio. The test programs are built into `tests\bin`. The
scripts build everything they need; the requirements are listed in [BUILDING.md](BUILDING.md).

The scripts use Visual Studio 2022 by default; add `-Vs 2026` for Visual Studio 2026. They only
touch Visual Studio's *experimental instance* (`/rootsuffix Exp`), never your normal Visual
Studio settings and extensions.

| Script | Purpose |
|---|---|
| `tests\1_install_in_experimental_vs.ps1` | Builds the Release VSIX and installs it into the experimental instance |
| `tests\2_test_value_merging_offline.ps1` | Offline checks of the value merging, no Visual Studio window needed |
| `tests\3_test_debugger_values.ps1 [-CSharp]` | Debugs a test program and checks what the debugger shows, with hex display off and on: plain values, members, arguments, format specifiers, minimum/maximum values, bit fields, unions, library types (STL, nullable, `DebuggerDisplay`), value editing (hex, negative, members, array elements, enums), and that side effects and function calls run only once |
| `tests\4_test_debug_restart.ps1 [-CSharp]` | Starts and stops debugging several times in one Visual Studio session |
| `tests\5_test_result_features.ps1 [-CSharp] [-Hex]` | Checks the features Visual Studio calls on a row: *Break When Value Changes* (C++), pinned members (C++ and C#), *Make Object ID* (C#) |
| `tests\6_test_hex_toggle_stress.ps1 [-CSharp] [-Toggles 100]` | Switches *Hexadecimal Display* many times while Watch, Locals and Call Stack are being filled, then checks the values shown in these windows |
| `tests\7_test_cppcli_unchanged.ps1` | Checks that C++/CLI (managed C++) looks exactly as without AlwaysHex: AlwaysHex only handles C and C++ in native code |
| `tests\8_test_large_data.ps1 [-CSharp]` | Large and deeply nested data (100,000 elements, a map with 1,000 entries, 2D and jagged arrays, 10 nesting levels, a linked list followed 100 nodes deep): values, numbers of children and generous time limits |
| `tests\9_test_breakpoints.ps1 [-CSharp]` | Tracepoint output, a conditional breakpoint with a hex literal, and (C++) data breakpoints and the Memory and Disassembly windows with integers that hold addresses, plus a breakpoint at an address |
| `tests\10_test_step_stress.ps1 [-CSharp] [-Steps 100]` | Steps through a loop many times while Watch, Locals and Call Stack are shown, and checks the values after every step |
| `tests\11_test_threads_exceptions.ps1 [-CSharp]` | Values in other stack frames and on other threads, at a thrown exception (`$exception` in C#) and in a `catch` block |
| `tests\12_test_soak.ps1 [-CSharp] [-Evaluations 5000]` | Thousands of evaluations and expansions: values stay correct, Visual Studio's memory and the time per evaluation must not keep growing |
| `tests\13_test_mixed_mode.ps1` | Mixed-mode debugging (C# and native C++ in one session): both show both radixes |
| `tests\14_test_return_values.ps1` | C++ return values in Autos: after stepping over a call, the "returned" rows show both radixes (hex display off and on), and a returned struct can be expanded |
| `tests\15_test_notepadpp.ps1 [-NppRoot <folder>]` | Real-world C++: debugs Notepad++ and stops at five breakpoints in different parts of it; integer locals, structs and classes with many members show both radixes, in both display modes, and both numbers of each value are the same number. Visual Studio 2026 only (see below) |
| `tests\run_release_tests.ps1 [-Vs 2022,2026] [-Only 8,9]` | Runs the installation and all test scripts and prints a summary with the result and duration of each step |
| `tests\run_coverage.ps1 [-Vs 2026]` | Optional: runs the tests with an instrumented `AlwaysHex.dll` and prints its line coverage per class (needs Visual Studio Professional or Enterprise) |
| `tests\vs_automation_helpers.ps1` | Shared helper functions used by the scripts above (not run directly) |
| `tests\ui_automation_helpers.ps1` | Helper functions for the scripts that select and read rows in the real debugger windows (not run directly) |

Scripts 5, 6, 7, 9, 10 and 14 use Windows UI Automation to select and read rows in the debugger
windows, and script 9 types addresses into the Memory and Disassembly windows. So the
experimental instance must stay visible on an unlocked desktop while the tests run; don't click
into it or type. The scripts move the mouse pointer to the top-left corner of the screen, so that
no data tip opens over the code.

**Notepad++ (script 15):** the test needs the Notepad++ source and a Debug x64 build of it. It looks
in `-NppRoot`, then in the folder named by the environment variable `ALWAYSHEX_NPP_ROOT`, then in
`tests\external\notepad-plus-plus` (ignored by git). If the source is missing there, the test
downloads the tested Notepad++ version from GitHub (with git, or as a zip without git); if the
build is missing, it builds it once with the selected Visual Studio, which takes several minutes.
Notepad++ runs with its own settings folder in `tests\bin`, so a Notepad++ you have open and your
Notepad++ settings are not used. The full release test runs it with Visual Studio 2026 only: in
Visual Studio 2022 17.14 the debugger's worker process can crash when the automation interface
reads the children of a not yet initialized local (random memory) all at once. This is a Visual
Studio bug that happens without AlwaysHex too; it was not seen in the debugger windows.

A full release test runs all scripts for both Visual Studio versions:
`tests\run_release_tests.ps1`. `tests\release_test_vs2022.cmd` and `tests\release_test_vs2026.cmd`
run it for one Visual Studio version each (double-click or run from a command prompt). The scripts
check the displayed values themselves; a failing step does not stop the run, and the summary at
the end lists every step with its result.

Back to the [README](README.md).

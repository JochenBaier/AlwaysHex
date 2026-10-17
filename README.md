

<img src="AlwaysHex%20Logo%20big.png" alt="AlwaysHex Logo big" width="444" />

#          AlwaysHex - Visual Studio Extension

**Show variable values in decimal and hex together while you debug in Visual Studio.**

<img src="debugger_view.png" alt="debugger_view" width="496" />



Visual Studio's debugger shows numbers either in decimal *or* in hex. Which one depends on the
*Hexadecimal Display* toggle, so you keep switching back and forth. AlwaysHex shows both:

| | Without AlwaysHex | With AlwaysHex |
|---|---|---|
| `int a = 100` | `100` | `100 (0x00000064)` |
| `int neg = -1` | `-1` | `-1 (0xffffffff)` |
| `int16_t i = 42` | `42` | `42 (0x002a)` |
| `char ch = 'a'` | `97 'a'` | `97 (0x61) 'a'` |
| `POINT pt` | `{x=1655 y=222}` | `{x=1655 (0x00000677) y=222 (0x000000de)}` |

The radix you picked with *Hexadecimal Display* always comes first. With hex display on,
`100` is shown as `0x00000064 (100)`.

## Where it works

- **Languages:** C, C++ and C#
- **Windows:** data tips (hover), Watch, Locals, Autos, struct/class members, array elements,
  and the Call Stack window
- **Visual Studio:** 2022 (17.x) and 2026 (18.x), Community, Professional and Enterprise, 64-bit
  (tested with Community 2022, Professional 2022 and Professional 2026)

There is nothing to configure: install it and start debugging.

**Copying a value:** *Copy Value* in the right-click menu copies both parts, for example
`100 (0x00000064)`. To copy only the first part, double-click the value and press Ctrl+C.

## Installation

1. Download `AlwaysHex.vsix` from the [Releases](../../releases) page.
2. Close Visual Studio and double-click the file. The installer lists the Visual Studio
   versions it can install into.
3. Start Visual Studio and debug as usual.

To turn AlwaysHex off, disable it under **Extensions → Manage Extensions** and restart Visual Studio.

**Not active after an update in Visual Studio 2026?** After updating an already installed
AlwaysHex, Visual Studio 2026 sometimes keeps using its old extension cache and starts without
it. Close Visual Studio, open a *Developer Command Prompt for VS 2026* and run
`devenv /updateconfiguration` once.

## How it works

AlwaysHex is a component for the Visual Studio debug engine ("Concord"). It registers itself
just above the built-in C/C++ and C# expression evaluators, so every request for a value reaches
it first:

1. AlwaysHex forwards the request to the built-in evaluator.
   - **C/C++:** it asks twice, once in your radix and once in the other one.
   - **C#:** it asks once and computes the other radix itself from the value and its type.
     Property getters are therefore never run twice.
2. It merges the two answers, `100` + `0x00000064` → `100 (0x00000064)`, and hands the result
   to Visual Studio.

The source code in [`AlwaysHex/AlwaysHexEvaluator.cs`](AlwaysHex/AlwaysHexEvaluator.cs) starts
with a detailed explanation, including the debugger terms it uses and the routing trick.

> [!WARNING]
>
> #### Undocumented Visual Studio behavior
>
> To pass requests on to the built-in evaluators, AlwaysHex relies on how Visual Studio routes them
> internally. This routing is not documented by Microsoft. It is tested with Visual Studio 2022
> 17.14 and Visual Studio 2026 18.11, but a future Visual Studio version may change it and need an
> update of AlwaysHex. If that ever happens, the debugger shows the normal single value or an
> evaluation error; it does not hang.

## Building from source

Requirements: Visual Studio 2022 or 2026 with the workloads ".NET desktop development"
(for the extension) and "Desktop development with C++" (for the C++ test program).
Everything else comes as NuGet packages, which MSBuild downloads automatically during the
build (`-restore`).

```powershell
# everything: extension and test programs
& "<Visual Studio>\MSBuild\Current\Bin\MSBuild.exe" AlwaysHex.sln -restore -p:Configuration=Release

# only the extension
& "<Visual Studio>\MSBuild\Current\Bin\MSBuild.exe" vsix\vsix.csproj -restore -p:Configuration=Release
```

The result is `vsix\bin\Release\AlwaysHex.vsix`.

### Release tests

The `tests` folder contains two small test programs that are part of the solution,
`TestCpp` (C++) and `TestCSharp` (C#), plus scripts that check AlwaysHex in a real Visual Studio.
The test programs are built into `tests\bin`. The scripts build everything they need.

The scripts use Visual Studio 2022 by default; add `-Vs 2026` for Visual Studio 2026. They only
touch Visual Studio's *experimental instance* (`/rootsuffix Exp`), never your normal Visual
Studio settings and extensions.

| Script | Purpose |
|---|---|
| `tests\1_install_in_experimental_vs.ps1` | Builds the Release VSIX and installs it into the experimental instance |
| `tests\2_test_value_merging_offline.ps1` | Offline checks of the value merging, no Visual Studio window needed |
| `tests\3_test_debugger_values.ps1 [-CSharp]` | Debugs a test program and prints what the debugger shows, with hex display off and on |
| `tests\4_test_debug_restart.ps1 [-CSharp]` | Starts and stops debugging several times in one Visual Studio session |
| `tests\vs_automation_helpers.ps1` | Shared helper functions used by the scripts above (not run directly) |

A full release test runs all four scripts in order. `tests\release_test_vs2022.cmd` and
`tests\release_test_vs2026.cmd` do that for one Visual Studio version each (double-click or run
from a command prompt). The scripts check the displayed values themselves; the files stop at the
first failing step and report it.

## AI usage

AlwaysHex was written by Claude (Claude Opus 5.5, an AI model by Anthropic), working in Claude
Code: the idea for how to hook into the debugger, the source code, the build and packaging setup,
the test programs and scripts, and most of this README.

I, Jochen, supervised the work: I described what I wanted, made the decisions (features,
name, license, supported Visual Studio versions) and tested the extension by hand, including in
real-world projects.

## License

[MIT](LICENSE) © 2026 Jochen Baier, email(at)jochen-baier.de

# Building AlwaysHex from source

Requirements: Visual Studio 2022 or 2026 with the workloads ".NET desktop development"
(for the extension) and "Desktop development with C++" (for the C++ test program), plus the
component "C++/CLI support" (for the C++/CLI test program).
Everything else comes as NuGet packages, which MSBuild downloads automatically during the
build (`-restore`).

```powershell
# everything: extension and test programs
& "<Visual Studio>\MSBuild\Current\Bin\MSBuild.exe" AlwaysHex.sln -restore -p:Configuration=Release

# only the extension
& "<Visual Studio>\MSBuild\Current\Bin\MSBuild.exe" vsix\vsix.csproj -restore -p:Configuration=Release
```

The result is `vsix\bin\Release\AlwaysHex.vsix`.

To check a build in a real Visual Studio, see the [release tests](RELEASE_TESTS.md).

Back to the [README](README.md).

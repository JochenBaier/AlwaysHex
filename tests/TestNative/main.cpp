// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

// Native half of the mixed-mode test program (debugged by tests\13_test_mixed_mode.ps1):
// TestMixed.exe (C#) calls native_add through P/Invoke.
extern "C" __declspec(dllexport) int __cdecl native_add(int lhs, short rhs)
{
    int sum = lhs + rhs;
    // BREAK_NATIVE
    return sum;
}

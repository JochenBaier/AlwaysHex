// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

// Managed half of the mixed-mode test program (debugged by tests\13_test_mixed_mode.ps1): calls
// native_add in TestNative.dll. The test driver starts this program and then attaches the native
// and the managed debugger, so the program first waits for a debugger.
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

static class Program
{
    [DllImport("TestNative.dll", CallingConvention = CallingConvention.Cdecl)]
    static extern int native_add(int lhs, short rhs);

    static int Main()
    {
        var deadline = DateTime.Now.AddMinutes(3);
        while (!Debugger.IsAttached && DateTime.Now < deadline)
            Thread.Sleep(100);
        // Give the debugger time to bind the breakpoints after attaching.
        Thread.Sleep(1000);

        int a = 100;
        short s = -42;
        // BREAK_MANAGED
        int r = native_add(a, s);
        return r;
    }
}

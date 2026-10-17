// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

// C# test target for the AlwaysHex debugger extension. The test driver (3_test_debugger_values.ps1 -CSharp)
// sets breakpoints on the first code line after each BREAK_* marker.
using System;

enum Color { Red = 1, Green = 2, Blue = 200 }

[Flags]
enum Access : byte { None = 0, Read = 1, Write = 2, Exec = 4 }

struct Point
{
    public int X;
    public ushort Y;
    public char C;
    public double D;
    public Color Col;
}

class Holder
{
    public int Field = 4096;
    public long Prop { get { return -2; } }
}

static class Program
{
    static int Add(int lhs, byte rhs)
    {
        // BREAK_ADD
        return lhs + rhs;
    }

    static int Main()
    {
        int a = 100;
        int neg = -1;
        uint u = 0xDEADBEEF;
        short s = -42;
        ushort us = 65535;
        long ll = -1234567890123L;
        ulong ull = 0xFFFFFFFFFFFFFFFFUL;
        byte b8 = 200;
        sbyte sb = -5;
        char ch = 'a';
        bool flag = true;
        float f = 1.5f;
        double d = 2.25;
        decimal money = 12.5m;
        int[] arr = { 1, 255, 4096 };
        Color col = Color.Blue;
        Access acc = Access.Read | Access.Exec;
        Point pt = new Point { X = 10, Y = 300, C = 'q', D = 3.5, Col = Color.Green };
        Holder h = new Holder();
        string str = "hello";
        IntPtr ip = new IntPtr(0x1234);

        // BREAK_MAIN
        int sink = Add(a, b8) + neg + (int)u + s + us + (int)ll + (int)ull + sb + ch + (flag ? 1 : 0)
            + (int)f + (int)d + (int)money + arr[2] + (int)col + (int)acc + pt.X + h.Field + (int)h.Prop
            + str.Length + ip.ToInt32();
        return sink;
    }
}

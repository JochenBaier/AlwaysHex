// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

// C++/CLI test target for AlwaysHex (debugged by tests\7_test_cppcli_unchanged.ps1). AlwaysHex
// handles native C/C++ only; C++/CLI has its own expression evaluator and must look exactly as
// without AlwaysHex. The test sets breakpoints on the first code line after each BREAK_* marker.
using namespace System;

ref class Box
{
public:
    int Value;
    Box() : Value(7) {}
};

static int add(int lhs, short rhs)
{
    // BREAK_ADD
    return lhs + rhs;
}

int main(array<String^>^ args)
{
    int a = 100;
    short s16 = -42;
    Box^ box = gcnew Box();
    String^ text = "managed";
    // BREAK_MAIN
    int sum = add(a, s16);
    Console::WriteLine(sum + box->Value + text->Length + args->Length);
    return 0;
}

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

// Test target for the AlwaysHex debugger extension. The test driver (3_test_debugger_values.ps1) sets
// breakpoints on the first code line after each BREAK_* marker.
#include <cstddef>
#include <cstdint>

enum Color { Red = 1, Green = 2, Blue = 200 };
enum class Mode : uint8_t { Off = 0, On = 7 };

struct Point
{
    int x;
    unsigned short y;
    char c;
    double d;
    Color col;
};

static int add(int lhs, unsigned char rhs)
{
    // BREAK_ADD
    return lhs + rhs;
}

int main()
{
    int a = 100;
    int neg = -1;
    unsigned int u = 0xDEADBEEF;
    short s = -42;
    unsigned short us = 65535;
    long l = 70000;
    long long ll = -1234567890123LL;
    unsigned long long ull = 0xFFFFFFFFFFFFFFFFull;
    char ch = 'a';
    unsigned char uc = 200;
    signed char sc = -5;
    wchar_t wc = L'Z';
    char16_t c16 = u'x';
    char32_t c32 = U'y';
    bool b = true;
    float f = 1.5f;
    double d = 2.25;
    int* p = &a;
    int arr[3] = { 1, 255, 4096 };
    uint8_t u8 = 0x7F;





    int16_t i = 42;






    int32_t i32 = 123456;
    size_t sz = 4096;
    Color col = Blue;
    Mode m = Mode::On;
    Point pt = { 10, 300, 'q', 3.5, Green };
    const char* str = "hello";

    // BREAK_MAIN

    volatile int sink = add(a, uc) + neg + u + s + us + l + (int)ll + (int)ull + ch + sc + wc + c16 + c32 + b
        + (int)f + (int)d + *p + arr[2] + u8 + i + i32 +(int)sz + col + (int)m + pt.x + str[0];
    return sink;
}

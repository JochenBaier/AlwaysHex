// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

// Test target for the AlwaysHex debugger extension. The test drivers (tests\*.ps1) set
// breakpoints on the first code line after each BREAK_* marker.
#include <climits>
#include <cstddef>
#include <cstdint>
#include <map>
#include <memory>
#include <optional>
#include <string>
#include <thread>
#include <vector>

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

// ---- Special values and library types (3_test_debugger_values.ps1) ----

enum Flags { FlagA = 1, FlagB = 2, FlagC = 4 };

struct Bits
{
    unsigned lo : 3;
    unsigned mid : 5;
    int sgn : 4;
};

union Overlay
{
    int32_t i;
    float f;
    uint8_t bytes[4];
};

// Evaluating countCall() in the debugger must run it exactly once.
static int g_calls = 0;
static int countCall()
{
    return ++g_calls;
}

static int special_values()
{
    int imin = INT_MIN;
    long long llmin = LLONG_MIN;
    unsigned long long umax = ULLONG_MAX;
    int8_t i8 = -128;
    uint16_t u16 = 0xFFFF;
    Bits bits = { 5, 17, -3 };
    Overlay ov;
    ov.i = 0x40490FDB;
    Flags fl = Flags(FlagA | FlagC);
    int target = 0x1234;
    int& ref = target;
    long hr = (long)0x80004005L;
    int nums[4] = { 16, 32, 48, 64 };
    int* pn = nums;
    std::string text = "hello";
    std::vector<int> vec = { 1, 2, 300 };
    std::map<int, int> mp = { { 1, 10 }, { 2, 300 } };
    std::shared_ptr<Point> sp = std::make_shared<Point>(Point{ 7, 300, 'z', 1.0, Red });
    std::optional<int> opt = 42;

    // BREAK_SPECIAL
    return imin + (int)llmin + (int)umax + i8 + u16 + bits.mid + ov.bytes[0] + fl + ref + (int)hr + pn[1]
        + (int)text.size() + vec[2] + mp[2] + sp->x + *opt + countCall();
}

// ---- Large and deeply nested data (8_test_large_data.ps1) ----

struct L9 { int v = 9; };
struct L8 { L9 n; int v = 8; };
struct L7 { L8 n; int v = 7; };
struct L6 { L7 n; int v = 6; };
struct L5 { L6 n; int v = 5; };
struct L4 { L5 n; int v = 4; };
struct L3 { L4 n; int v = 3; };
struct L2 { L3 n; int v = 2; };
struct L1 { L2 n; int v = 1; };
struct L0 { L1 n; int v = 0; };

struct Node
{
    int v;
    Node* next;
};

static Node g_nodes[1000];
static int g_huge[20000];

static int big_data()
{
    std::vector<int> big(100000);
    for (int i = 0; i < 100000; i++)
        big[i] = i;
    std::map<int, int> bigmap;
    for (int i = 0; i < 1000; i++)
        bigmap[i] = i * 2;
    int grid[3][4];
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 4; c++)
            grid[r][c] = r * 16 + c;
    L0 deep;
    for (int i = 0; i < 1000; i++)
    {
        g_nodes[i].v = i;
        g_nodes[i].next = i + 1 < 1000 ? &g_nodes[i + 1] : nullptr;
    }
    Node* head = &g_nodes[0];
    for (int i = 0; i < 20000; i++)
        g_huge[i] = i;

    // BREAK_BIG
    return big[99999] + bigmap[999] + grid[2][3] + deep.n.n.n.n.n.n.n.n.n.v + head->v + g_huge[19999];
}

// ---- Address and data breakpoints (9_test_breakpoints.ps1) ----

static int g_counter = 5;

static int twice(int v)
{
    return v * 2;
}

static int addresses()
{
    int local = 100;
    uintptr_t addr = (uintptr_t)&g_counter;
    uintptr_t code = (uintptr_t)&twice;
    // BREAK_ADDR
    int r = twice(21);
    g_counter++;
    // BREAK_ADDR_END
    return r + local + (int)addr + (int)code;
}

// ---- Return values in Autos (14_test_return_values.ps1) ----

static Point make_point(int v)
{
    Point r = { v, (unsigned short)(v + 1), 'r', 0.5, Blue };
    return r;
}

static int return_values()
{
    // BREAK_RETURN
    Point rp = make_point(42);
    int rt = twice(21);
    return rp.x + rt;
}

// ---- Stepping (10_test_step_stress.ps1) and conditional breakpoints ----

static int step_loop()
{
    int sum = 0;
    for (int i = 0; i < 1000; i++)
    {
        // BREAK_STEP
        sum += i;
    }
    return sum;
}

// ---- Threads, frames and exceptions (11_test_threads_exceptions.ps1) ----

static int worker(int n)
{
    int doubled = n * 2;
    // BREAK_WORKER
    return doubled;
}

static int threads()
{
    int before = 0x55;
    int result = 0;
    std::thread t([&result] { result = worker(0x77); });
    t.join();
    return before + result;
}

struct TestError
{
    int code;
};

static int exceptions()
{
    int code = 0x1234;
    try
    {
        throw TestError{ code };
    }
    catch (const TestError& e)
    {
        // BREAK_CATCH
        return e.code;
    }
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
    sink += special_values();
    sink += big_data();
    sink += addresses();
    sink += return_values();
    sink += step_loop();
    sink += threads();
    sink += exceptions();
    return sink;
}

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

// C# test target for the AlwaysHex debugger extension. The test drivers (tests\*.ps1 -CSharp)
// set breakpoints on the first code line after each BREAK_* marker.
using System;
using System.Collections;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Data;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Xml.Linq;

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

// Reading Once in the debugger must run the getter exactly once (3_test_debugger_values.ps1).
// Once appears in no source line, so no debugger window runs it on its own (Autos evaluates the
// expressions of the current line, e.g. cnt.Next in SpecialValues()).
class Counter
{
    public static int Calls;
    public static int OnceCalls;
    public int Next { get { return ++Calls; } }
    public int Once { get { return ++OnceCalls; } }
}

[DebuggerDisplay("Count = {Count}, Max = {Max}")]
class Stats
{
    public int Count = 3;
    public int Max = 300;
}

// Deeply nested and linked data (8_test_large_data.ps1).
class L9 { public int v = 9; }
class L8 { public L9 n = new L9(); public int v = 8; }
class L7 { public L8 n = new L8(); public int v = 7; }
class L6 { public L7 n = new L7(); public int v = 6; }
class L5 { public L6 n = new L6(); public int v = 5; }
class L4 { public L5 n = new L5(); public int v = 4; }
class L3 { public L4 n = new L4(); public int v = 3; }
class L2 { public L3 n = new L3(); public int v = 2; }
class L1 { public L2 n = new L2(); public int v = 1; }
class L0 { public L1 n = new L1(); public int v = 0; }

class Node
{
    public int v;
    public Node next;
}

static class Program
{
    static int Add(int lhs, byte rhs)
    {
        // BREAK_ADD
        return lhs + rhs;
    }

    // ---- Special values and library types (3_test_debugger_values.ps1) ----
    static int SpecialValues()
    {
        int imin = int.MinValue;
        long lmin = long.MinValue;
        ulong umax = ulong.MaxValue;
        sbyte s8 = -128;
        int? ni = 5;
        int? nnull = null;
        nint nn = 0x10;
        Access perm = Access.Read | Access.Write;
        Stats stats = new Stats();
        Counter cnt = new Counter();
        var list = new List<int> { 1, 2, 300 };
        var dict = new Dictionary<string, int> { { "one", 1 }, { "big", 300 } };
        string text = "hello";
        object boxed = 300;

        // BREAK_SPECIAL
        return imin + (int)lmin + (int)umax + s8 + ni.Value + (nnull ?? 0) + (int)nn + (int)perm + stats.Max
            + cnt.Next + list[2] + dict["big"] + text.Length + (int)boxed;
    }

    // ---- Large and deeply nested data (8_test_large_data.ps1) ----
    static int BigData()
    {
        var big = new int[100000];
        for (int i = 0; i < big.Length; i++)
            big[i] = i;
        var list = new List<int>(big);
        var bigmap = new Dictionary<int, int>();
        for (int i = 0; i < 1000; i++)
            bigmap[i] = i * 2;
        var grid = new int[3, 4];
        for (int r = 0; r < 3; r++)
            for (int c = 0; c < 4; c++)
                grid[r, c] = r * 16 + c;
        var jagged = new[] { new[] { 1, 2 }, new[] { 300 } };
        var deep = new L0();
        Node head = null;
        for (int i = 999; i >= 0; i--)
            head = new Node { v = i, next = head };

        // BREAK_BIG
        return big[99999] + list.Count + bigmap[999] + grid[2, 3] + jagged[1][0] + deep.n.n.n.n.n.n.n.n.n.v + head.v;
    }

    // ---- Stepping (10_test_step_stress.ps1) and conditional breakpoints ----
    static int StepLoop()
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
    static int Worker(int n)
    {
        int doubled = n * 2;
        // BREAK_WORKER
        return doubled;
    }

    static int Threads()
    {
        int before = 0x55;
        int result = 0;
        var t = new Thread(() => { result = Worker(0x77); });
        t.Start();
        t.Join();
        return before + result;
    }

    static int Exceptions()
    {
        int code = 0x1234;
        try
        {
            throw new InvalidOperationException("boom");
        }
        catch (InvalidOperationException e)
        {
            // BREAK_CATCH
            return e.HResult + code;
        }
    }

    // ---- Many .NET types at once (6_test_hex_toggle_stress.ps1 -CSharp) ----
    // DateOnly, TimeOnly and System.Text.Json are missing: they do not exist in .NET Framework 4.7.2.
#nullable enable
    static int AllTypes()
    {
        // Numeric types: all minimum and maximum values.
        sbyte sbMin = sbyte.MinValue, sbMax = sbyte.MaxValue;
        byte bMin = byte.MinValue, bMax = byte.MaxValue;
        short sMin = short.MinValue, sMax = short.MaxValue;
        ushort usMin = ushort.MinValue, usMax = ushort.MaxValue;
        int iMin = int.MinValue, iMax = int.MaxValue;
        uint uiMin = uint.MinValue, uiMax = uint.MaxValue;
        long lMin = long.MinValue, lMax = long.MaxValue;
        ulong ulMin = ulong.MinValue, ulMax = ulong.MaxValue;
        // nint/nuint.MinValue/MaxValue need .NET 7; this is the same for x64.
        nint niMin = unchecked((nint)long.MinValue), niMax = unchecked((nint)long.MaxValue);
        nuint nuiMin = 0, nuiMax = unchecked((nuint)ulong.MaxValue);
        float fMin = float.MinValue, fMax = float.MaxValue;
        float fEpsilon = float.Epsilon;
        float fNaN = float.NaN;
        float fInfinity = float.PositiveInfinity;
        double dMin = double.MinValue, dMax = double.MaxValue;
        double dEpsilon = double.Epsilon;
        double dNaN = double.NaN;
        double dInfinity = double.PositiveInfinity;
        decimal mMin = decimal.MinValue, mMax = decimal.MaxValue;
        char cMin = char.MinValue, cMax = char.MaxValue;
        bool boolFalse = false, boolTrue = true;
        int? nullableValue = 123, nullableEmpty = null;

        // Strings, dates, GUIDs, cultures.
        string emptyString = string.Empty;
        string text = "Hello Visual Studio debugger";
        string? nullString = null;
        string unicodeText = "Hello \U0001F30D Gr\u00FC\u00DFe \u65E5\u672C\u8A9E";
        DateTime dateMin = DateTime.MinValue;
        DateTime dateMax = DateTime.MaxValue;
        DateTime now = DateTime.Now;
        DateTime utcNow = DateTime.UtcNow;
        DateTimeOffset offsetNow = DateTimeOffset.Now;
        TimeSpan duration = TimeSpan.FromHours(27.5);
        Guid guid = Guid.NewGuid();
        Guid emptyGuid = Guid.Empty;
        CultureInfo culture = CultureInfo.GetCultureInfo("de-DE");
        TimeZoneInfo localTimeZone = TimeZoneInfo.Local;

        // Arrays.
        int[] emptyArray = new int[0];
        int[] numbers = { 1, 2, 3, 4, 5, 100 };
        string[] names = { "Alice", "Bob", "Charlie" };
        int[,] matrix = { { 1, 2, 3 }, { 4, 5, 6 } };
        int[][] jagged = { new[] { 1, 2 }, new[] { 3, 4, 5 } };
        object[] mixedArray = { 42, "hello", DateTime.Today, guid };
        ArrayList legacyArrayList = new() { 1, "two", 3.0 };

        // Lists, dictionaries, sets, queues, stacks.
        List<int> list = new() { 10, 20, 30, 40, 50 };
        List<string> stringList = new() { "Red", "Green", "Blue" };
        List<List<int>> nestedList = new() { new() { 1, 2, 3 }, new() { 4, 5, 6 } };
        Dictionary<string, int> dictionary = new() { ["Alice"] = 30, ["Bob"] = 25, ["Charlie"] = 40 };
        Dictionary<string, List<string>> nestedDictionary = new()
        {
            ["Fruits"] = new() { "Apple", "Pear" },
            ["Colors"] = new() { "Red", "Blue" }
        };
        Hashtable hashtable = new() { ["Name"] = "Alice", ["Age"] = 30 };
        HashSet<int> hashSet = new() { 1, 2, 3, 3, 4 };
        SortedSet<int> sortedSet = new() { 50, 10, 30, 20, 40 };
        SortedDictionary<string, int> sortedDictionary = new() { ["Charlie"] = 3, ["Alice"] = 1, ["Bob"] = 2 };
        SortedList<int, string> sortedList = new() { [3] = "Three", [1] = "One", [2] = "Two" };
        Queue<string> queue = new();
        queue.Enqueue("First");
        queue.Enqueue("Second");
        queue.Enqueue("Third");
        Stack<string> stack = new();
        stack.Push("First");
        stack.Push("Second");
        stack.Push("Third");
        LinkedList<string> linkedList = new();
        linkedList.AddLast("First");
        linkedList.AddLast("Second");
        linkedList.AddFirst("Zero");

        // Collections with notification or concurrency.
        ObservableCollection<string> observable = new() { "One", "Two", "Three" };
        ConcurrentDictionary<string, int> concurrentDictionary = new();
        concurrentDictionary["First"] = 1;
        concurrentDictionary["Second"] = 2;

        // Tuples, anonymous objects, boxed values.
        var tuple = (Id: 101, Name: "Alice", Active: true);
        var anonymousObject = new
        {
            Id = 1,
            Name = "Example",
            Address = new { City = "Nuremberg", Country = "Germany" },
            Scores = new[] { 10, 20, 30 }
        };
        object boxedInteger = 123;
        object boxedDate = DateTime.Now;

        // LINQ results.
        var filteredNumbers = numbers.Where(x => x > 10).ToList();
        var groupedNumbers = numbers.GroupBy(x => x % 2).ToList();
        var projectedNumbers = numbers.Select(x => new { Original = x, Square = x * x, IsEven = x % 2 == 0 }).ToList();
        var lookup = names.ToLookup(x => x.Length);
        var numberRange = Enumerable.Range(1, 10).ToArray();

        // DataTable, DataSet, DataView.
        DataTable table = new("Employees");
        table.Columns.Add("Id", typeof(int));
        table.Columns.Add("Name", typeof(string));
        table.Columns.Add("Salary", typeof(decimal));
        table.Columns.Add("Active", typeof(bool));
        table.Rows.Add(1, "Alice", 65000m, true);
        table.Rows.Add(2, "Bob", 72000m, true);
        table.Rows.Add(3, "Charlie", 48000m, false);
        DataSet dataSet = new("Company");
        dataSet.Tables.Add(table);
        DataView dataView = new(table) { Sort = "Salary DESC", RowFilter = "Active = true" };
        DataRow firstRow = table.Rows[0];
        object firstRowName = firstRow["Name"];
        DataColumnCollection columns = table.Columns;
        DataRowCollection rows = table.Rows;

        // XML tree.
        XDocument xmlDocument = XDocument.Parse(
            "<company>" +
            "<employee id=\"1\" active=\"true\"><name>Alice</name><department>Engineering</department></employee>" +
            "<employee id=\"2\" active=\"false\"><name>Bob</name><department>Finance</department></employee>" +
            "</company>");
        XElement? rootElement = xmlDocument.Root;
        IEnumerable<XElement> employeeElements = rootElement?.Elements("employee") ?? Enumerable.Empty<XElement>();
        XElement? firstEmployee = employeeElements.FirstOrDefault();
        XAttribute? employeeIdAttribute = firstEmployee?.Attribute("id");

        // Regular expressions.
        Regex emailRegex = new(@"^[^@\s]+@[^@\s]+\.[^@\s]+$", RegexOptions.Compiled);
        Match emailMatch = emailRegex.Match("alice@example.com");
        MatchCollection allMatches = Regex.Matches("Order 123, Order 456, Order 789", @"\d+");

        // Streams and binary data.
        byte[] buffer = Encoding.UTF8.GetBytes("Debug binary data");
        MemoryStream memoryStream = new(buffer);
        BinaryReader binaryReader = new(memoryStream, Encoding.UTF8, leaveOpen: true);
        int streamLength = (int)memoryStream.Length;
        long streamPosition = memoryStream.Position;

        // Exceptions and stack traces.
        Exception exampleException = new InvalidOperationException(
            "Example debugging exception", new ArgumentException("Inner exception"));
        Exception? noException = null;
        string exceptionMessage = exampleException.Message;
        Exception? innerException = exampleException.InnerException;
        StackTrace currentStackTrace = new(true);

        // Network types.
        Uri uri = new("https://example.com/path?id=42");
        IPAddress ipv4 = IPAddress.Parse("192.168.1.100");
        IPAddress ipv6 = IPAddress.IPv6Loopback;
        IPEndPoint endpoint = new(ipv4, 8080);

        // Values to watch.
        int listCount = list.Count;
        int listMin = list.Min();
        int listMax = list.Max();
        int dictionaryCount = dictionary.Count;
        bool dictionaryHasAlice = dictionary.ContainsKey("Alice");
        int matrixValue = matrix[1, 2];
        string? nullableString = null;

        // BREAK_TYPES
        int sink = sbMin + bMax + sMin + usMax + iMin + (int)uiMax + (int)lMin + (int)ulMax + (int)niMin + (int)nuiMax
            + (int)fMax + (int)dMin + (int)mMax + cMax + (boolTrue ? 1 : 0) + (nullableValue ?? 0) + (nullableEmpty ?? 0)
            + emptyString.Length + text.Length + (nullString?.Length ?? 0) + unicodeText.Length + dateMin.Year + dateMax.Year
            + now.Second + utcNow.Second + offsetNow.Second + duration.Hours + guid.GetHashCode() + emptyGuid.GetHashCode()
            + culture.LCID + localTimeZone.BaseUtcOffset.Hours + emptyArray.Length + matrix.Length + jagged.Length
            + mixedArray.Length + legacyArrayList.Count + stringList.Count + nestedList.Count + nestedDictionary.Count
            + hashtable.Count + hashSet.Count + sortedSet.Count + sortedDictionary.Count + sortedList.Count + queue.Count
            + stack.Count + linkedList.Count + observable.Count + concurrentDictionary.Count + tuple.Id + anonymousObject.Id
            + (int)boxedInteger + ((DateTime)boxedDate).Second + filteredNumbers.Count + groupedNumbers.Count
            + projectedNumbers.Count + lookup.Count + numberRange.Length + dataSet.Tables.Count + dataView.Count
            + firstRowName.ToString()!.Length + columns.Count + rows.Count + (employeeIdAttribute?.Value.Length ?? 0)
            + allMatches.Count + (emailMatch.Success ? 1 : 0) + binaryReader.ReadByte() + streamLength + (int)streamPosition
            + exceptionMessage.Length + (noException == null ? 1 : 0) + (innerException?.Message.Length ?? 0)
            + currentStackTrace.FrameCount + uri.Port + ipv6.GetHashCode() + endpoint.Port + listCount + listMin + listMax
            + dictionaryCount + (dictionaryHasAlice ? 1 : 0) + matrixValue + (nullableString?.Length ?? 0)
            + (int)fMin + (int)fEpsilon + (float.IsNaN(fNaN) ? 1 : 0) + (float.IsInfinity(fInfinity) ? 1 : 0)
            + (int)dMax + (int)dEpsilon + (double.IsNaN(dNaN) ? 1 : 0) + (double.IsInfinity(dInfinity) ? 1 : 0)
            + (int)mMin + cMin + (boolFalse ? 1 : 0) + sbMax + bMin + sMax + usMin + iMax + (int)uiMin + (int)lMax
            + (int)ulMin + (int)niMax + (int)nuiMin;
        binaryReader.Dispose();
        memoryStream.Dispose();
        return sink;
    }
#nullable restore

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
        sink += SpecialValues();
        sink += BigData();
        sink += StepLoop();
        sink += Threads();
        sink += Exceptions();
        sink += AllTypes();
        return sink;
    }
}

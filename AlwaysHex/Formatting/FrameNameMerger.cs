// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using System.Collections.Generic;
using System.Text;
using System.Text.RegularExpressions;

namespace AlwaysHex
{
  /// <summary>
  /// Call Stack window: puts both radixes into the argument values of a frame name,
  /// e.g. "add(int lhs=100 (0x00000064), unsigned char rhs=200 (0xc8) 'È')". Only looks at text.
  /// </summary>
  internal static class FrameNameMerger
  {
    // One argument of the argument list whose whole value is a char literal: "unsigned char
    // rhs='È'", "wchar_t w=L'Z'", "char c = u'x'". Applied to a single argument only.
    private static readonly Regex CharArgument = new Regex(@"^(?<head>.*?)(?<![A-Za-z0-9_])(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<literal>(?:u8|u|U|L)?'(?:[^'\\]|\\.)*')\s*$",
        RegexOptions.Singleline);

    /// <summary>
    /// Inserts the other radix after each integer argument value of a frame name, using
    /// the frame name rendered in the other radix. Returns null when nothing pairs up.
    /// (Text inside string values is the same in both renderings and is copied unchanged.)
    /// </summary>
    internal static string MergeFrameName(string name, string other, bool nameIsHex)
    {
      return ValueMerger.MergeAssignedNumbers(name, other, nameIsHex, int.MaxValue);
    }

    /// <summary>True when the frame name has an argument whose value is a bare char literal.</summary>
    internal static bool HasCharArgument(string frameName)
    {
      List<Match> found = FindCharArguments(frameName);
      return found != null && found.Count > 0;
    }

    /// <summary>
    /// Replaces bare char-literal argument values with the full value from
    /// <paramref name="argumentValues"/> ("rhs='È'" -> "rhs=200 (0xc8) 'È'") when that value
    /// ends with the same literal. Only real arguments of the argument list are replaced, never
    /// text inside a string value such as s="c='a')". Returns null when nothing was replaced or
    /// the frame name cannot be split into arguments with certainty.
    /// </summary>
    internal static string ReplaceCharArguments(string frameName, IDictionary<string, string> argumentValues)
    {
      if (string.IsNullOrEmpty(frameName) || argumentValues == null || argumentValues.Count == 0)
      {
        return null;
      }

      List<Match> found = FindCharArguments(frameName);

      if (found == null || found.Count == 0)
      {
        return null;
      }

      var result = new StringBuilder();
      int pos = 0;
      bool changed = false;

      foreach (Match m in found)
      {
        // Match indexes are relative to the whole frame name (see FindCharArguments).
        Group literal = m.Groups["literal"];
        string value;

        if (argumentValues.TryGetValue(m.Groups["name"].Value, out value) && value.EndsWith(" " + literal.Value, StringComparison.Ordinal))
        {
          result.Append(frameName, pos, literal.Index - pos).Append(value);
          pos = literal.Index + literal.Length;
          changed = true;
        }
      }

      if (!changed)
      {
        return null;
      }

      result.Append(frameName, pos, frameName.Length - pos);
      return result.ToString();
    }

    /// <summary>
    /// The arguments of the frame's argument list whose value is a bare char literal, in text
    /// order, with indexes into <paramref name="frameName"/>. The argument list is the last
    /// top-level "(...)" (the name before it can contain "operator()" or "&lt;lambda_1&gt;", the
    /// text after it " Line 12"); arguments are split at its top-level commas. Strings ("...")
    /// and char literals ('...') are skipped as a whole, with backslash escapes, so commas,
    /// brackets, quotes and "x='a'" inside a string value never count. MSVC symbol names
    /// written as `...' ("`anonymous namespace'::f") are skipped as a whole too, so their
    /// closing apostrophe is not taken for a char literal. Returns null when the
    /// text is not certain: unterminated quote, unbalanced brackets, no argument list, or the
    /// same argument name twice.
    /// </summary>
    private static List<Match> FindCharArguments(string frameName)
    {
      if (string.IsNullOrEmpty(frameName))
      {
        return null;
      }

      // One pass: find the last top-level "(...)" and the top-level commas inside it.
      var open = new Stack<char>();       // the open (, { and [ brackets
      int listStart = -1, listEnd = -1;   // the parentheses of the last top-level group
      int groupStart = -1;
      var commas = new List<int>();
      var groupCommas = new List<int>();

      for (int i = 0; i < frameName.Length; i++)
      {
        char ch = frameName[i];

        if (ch == '`' || ch == '"' || ch == '\'')
        {
          int end = ch == '`' ? SkipBacktickName(frameName, i) : SkipQuoted(frameName, i);

          if (end < 0)
          {
            return null;            // unterminated: the text cannot be read safely
          }

          i = end;
          continue;
        }

        if (ch == '(' || ch == '{' || ch == '[')
        {
          if (open.Count == 0 && ch == '(')
          {
            groupStart = i;
            groupCommas.Clear();
          }

          open.Push(ch);
        }
        else if (ch == ')' || ch == '}' || ch == ']')
        {
          if (open.Count == 0 || open.Pop() != (ch == ')' ? '(' : ch == '}' ? '{' : '['))
          {
            return null;            // unbalanced or mismatched brackets
          }

          if (open.Count == 0 && ch == ')' && groupStart >= 0)
          {
            listStart = groupStart;
            listEnd = i;
            commas = new List<int>(groupCommas);
            groupStart = -1;
          }
        }
        else if (ch == ',' && open.Count == 1 && groupStart >= 0)
        {
          groupCommas.Add(i);
        }
      }

      if (open.Count != 0 || listStart < 0)
      {
        return null;
      }

      var found = new List<Match>();
      var names = new HashSet<string>(StringComparer.Ordinal);
      int start = listStart + 1;
      commas.Add(listEnd);

      foreach (int end in commas)
      {
        // Match(input, beginning, length) treats the range as the whole input (^, $ and the
        // look-behind stop at its ends); the indexes of the match refer to frameName.
        Match m = CharArgument.Match(frameName, start, end - start);

        if (m.Success)
        {
          if (!names.Add(m.Groups["name"].Value))
          {
            return null;            // the same name twice: which one is meant?
          }

          found.Add(m);
        }

        start = end + 1;
      }

      return found;
    }

    /// <summary>
    /// Index of the apostrophe that closes the MSVC symbol name starting with the backtick at
    /// <paramref name="start"/>, or -1 when it is not closed. Such names nest:
    /// "`anonymous namespace'", "`vftable'", "`dynamic initializer for 'g_x''". Inside one, a
    /// backtick or an apostrophe after a space (" 'g_x") opens a nested name; any other
    /// apostrophe closes the innermost one.
    /// </summary>
    private static int SkipBacktickName(string text, int start)
    {
      int depth = 1;

      for (int i = start + 1; i < text.Length; i++)
      {
        char ch = text[i];

        if (ch == '`' || (ch == '\'' && text[i - 1] == ' '))
        {
          depth++;
        }
        else if (ch == '\'' && --depth == 0)
        {
          return i;
        }
      }

      return -1;
    }

    /// <summary>
    /// Index of the closing quote of the string or char literal that starts at
    /// <paramref name="start"/>, or -1 when it is not closed. A backslash escapes the next
    /// character (\" \' \\ \x41 ...).
    /// </summary>
    private static int SkipQuoted(string text, int start)
    {
      char quote = text[start];

      for (int i = start + 1; i < text.Length; i++)
      {
        if (text[i] == '\\')
        {
          i++;
        }
        else if (text[i] == quote)
        {
          return i;
        }
      }

      return -1;
    }
  }
}

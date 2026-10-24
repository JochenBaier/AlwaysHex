// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using System.Collections.Generic;
using System.Globalization;

namespace AlwaysHex
{
  /// <summary>
  /// C#: the other radix is computed here from the value text and the integer type
  /// (used by AlwaysHexClrFormatter, the server-side C# component). C# has no typedefs, so
  /// "short" always means 16-bit signed.
  /// </summary>
  internal static class CSharpFormatter
  {
    // C# has no typedefs, so the type name alone gives width and signedness.
    private static readonly Dictionary<string, IntType> CSharpIntTypes = new Dictionary<string, IntType>
        {
            { "sbyte", new IntType(8, true) },
            { "byte", new IntType(8, false) },
            { "short", new IntType(16, true) },
            { "ushort", new IntType(16, false) },
            { "char", new IntType(16, false) },
            { "int", new IntType(32, true) },
            { "uint", new IntType(32, false) },
            { "long", new IntType(64, true) },
            { "ulong", new IntType(64, false) },
        };

    /// <summary>
    /// "100" [int] -> "100 (0x00000064)", "0x0061 'a'" [char] -> "0x0061 (97) 'a'".
    /// Hex is printed at the type's own width ("-42" [short] -> "0xffd6"); the C# EE's hex
    /// for short/sbyte is sign-extended to 32 bits, so only the low bits are used.
    /// Returns null for anything that is not one of the integer types above.
    /// </summary>
    internal static string FormatOtherRadix(string value, string type, bool valueIsHex)
    {
      IntType t;

      if (string.IsNullOrEmpty(value) || type == null || !CSharpIntTypes.TryGetValue(type, out t))
      {
        return null;
      }

      // Split "97 'a'" into the number "97" and the rest " 'a'".
      string number = value;
      string rest = "";
      int space = value.IndexOf(' ');

      if (space > 0)
      {
        number = value.Substring(0, space);
        rest = value.Substring(space);
      }

      // Parse the number into its raw bit pattern.
      ulong bits;

      if (valueIsHex)
      {
        if (!number.StartsWith("0x", StringComparison.Ordinal) ||
            !ulong.TryParse(number.Substring(2), NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out bits))
        {
          return null;
        }
      }
      else if (t.Signed)
      {
        long signedValue;

        if (!long.TryParse(number, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out signedValue))
        {
          return null;
        }

        bits = unchecked((ulong)signedValue);
      }
      else if (!ulong.TryParse(number, NumberStyles.None, CultureInfo.InvariantCulture, out bits))
      {
        return null;
      }

      // Keep only the type's own bits (two's complement for negative numbers).
      ulong mask = t.Bits == 64 ? ulong.MaxValue : (1UL << t.Bits) - 1;
      bits &= mask;

      // Print the bits in the other radix: hex with leading zeros up to the type's
      // width, or decimal (negative if the sign bit of a signed type is set).
      string other;

      if (!valueIsHex)
      {
        other = "0x" + bits.ToString("x" + (t.Bits / 4), CultureInfo.InvariantCulture);
      }
      else if (t.Signed && t.Bits < 64 && (bits & (1UL << (t.Bits - 1))) != 0)
      {
        other = unchecked((long)(bits | ~mask)).ToString(CultureInfo.InvariantCulture);
      }
      else if (t.Signed)
      {
        other = unchecked((long)bits).ToString(CultureInfo.InvariantCulture);
      }
      else
      {
        other = bits.ToString(CultureInfo.InvariantCulture);
      }

      return number + " (" + other + ")" + rest;
    }
  }
}

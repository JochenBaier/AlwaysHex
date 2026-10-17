// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using System.Globalization;

namespace AlwaysHex
{
    /// <summary>
    /// Checks whether a decimal and a hex number from the EE are the same value, so that two
    /// renderings that disagree are never shown as a pair.
    /// </summary>
    internal static class RadixNumbers
    {
        // The first number must be in the user's radix and the second in the other one, and both
        // must be the same value: two renderings that disagree are never shown as a pair.
        internal static bool IsPair(string first, string second, bool firstIsHex)
        {
            bool firstHex = first.StartsWith("0x", StringComparison.Ordinal);
            bool secondHex = second.StartsWith("0x", StringComparison.Ordinal);
            if (firstHex != firstIsHex || secondHex == firstIsHex)
                return false;
            return firstIsHex ? SameNumber(second, first) : SameNumber(first, second);
        }

        /// <summary>
        /// True when the decimal number and the hex number ("0x" + digits) are the same value
        /// for an integer as wide as the hex number: "100" / "0x00000064", "-1" / "0xffffffff",
        /// "-42" / "0xffd6" (16 bit). The EE prints hex padded to the type's width.
        /// </summary>
        internal static bool SameNumber(string dec, string hex)
        {
            string digits = hex.Substring(2);
            ulong hexValue;
            if (digits.Length == 0 || digits.Length > 16 ||
                !ulong.TryParse(digits, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out hexValue))
                return false;

            ulong decBits;
            bool negative = dec.StartsWith("-", StringComparison.Ordinal);
            if (negative)
            {
                long signedValue;
                if (!long.TryParse(dec, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out signedValue))
                    return false;
                decBits = unchecked((ulong)signedValue);
            }
            else if (!ulong.TryParse(dec, NumberStyles.None, CultureInfo.InvariantCulture, out decBits))
            {
                return false;
            }

            int bits = digits.Length * 4;
            ulong mask = bits == 64 ? ulong.MaxValue : (1UL << bits) - 1;
            if ((decBits & mask) != hexValue)
                return false;
            // The decimal value must fit into that width: a positive number has only zero bits
            // above it; a negative one has only one bits above it (sign extension) and the sign
            // bit of the hex value set ("-129" is not "0x7f").
            if (!negative)
                return (decBits & ~mask) == 0;
            return (decBits | mask) == ulong.MaxValue && (hexValue & (1UL << (bits - 1))) != 0;
        }
    }
}

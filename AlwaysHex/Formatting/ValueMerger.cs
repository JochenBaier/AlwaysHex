// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System.Text;
using System.Text.RegularExpressions;

namespace AlwaysHex
{
    /// <summary>
    /// C/C++: combines two renderings of the same value from the EE, one per radix, into one
    /// display string. Only looks at text.
    /// </summary>
    /// <remarks>
    /// "valueIsHex" says which radix the first string is in (the user's radix); the result
    /// always starts with that one. The functions return null when the two strings do not look
    /// like the same number in decimal and hex: then the caller keeps the original string.
    /// </remarks>
    internal static class ValueMerger
    {
        // "<number><rest>", e.g. "100", "0x00000064", "97 'a'", "0x61 L'a'"
        private static readonly Regex LeadingNumber = new Regex(@"^(-?[0-9]+|0x[0-9a-fA-F]+)(\s.*)?$", RegexOptions.Singleline);
        // "<name> (<number><rest>)", e.g. enum display "Red (1)" or "On (7 '\a')"
        private static readonly Regex TrailingNumber = new Regex(@"^(.*\S) \((-?[0-9]+|0x[0-9a-fA-F]+)(\s.*)?\)$", RegexOptions.Singleline);

        // An integer argument value: right after "=" (C++ "lhs=100", C# "lhs = 100"), not part
        // of a longer token such as "1.5" or "100abc".
        private static readonly Regex ArgumentValue = new Regex(@"(?<==\s*)(-?(?:0x[0-9a-fA-F]+|[0-9]+))(?![0-9a-zA-Z_.])");

        // Struct summaries ("{x=1655 y=222}") get both radixes only up to this many numbers,
        // so big classes keep a readable one-line summary.
        private const int MaxSummaryPairs = 4;

        /// <summary>
        /// A single value:
        /// "100" / "0x00000064" -> "100 (0x00000064)",
        /// "97 'a'" / "0x61 'a'" -> "97 (0x61) 'a'",
        /// enum "Blue (200)" / "Blue (0x000000c8)" -> "Blue (200 | 0x000000c8)".
        /// Pointers, floats, strings and bools look the same in both radixes and are not changed.
        /// </summary>
        internal static string MergeValue(string value, string other, bool valueIsHex)
        {
            if (string.IsNullOrEmpty(value) || string.IsNullOrEmpty(other) || value == other)
                return null;

            Match a = LeadingNumber.Match(value);
            Match b = LeadingNumber.Match(other);
            if (a.Success && b.Success && a.Groups[2].Value == b.Groups[2].Value && RadixNumbers.IsPair(a.Groups[1].Value, b.Groups[1].Value, valueIsHex))
                return a.Groups[1].Value + " (" + b.Groups[1].Value + ")" + a.Groups[2].Value;

            a = TrailingNumber.Match(value);
            b = TrailingNumber.Match(other);
            if (a.Success && b.Success && a.Groups[1].Value == b.Groups[1].Value && a.Groups[3].Value == b.Groups[3].Value &&
                RadixNumbers.IsPair(a.Groups[2].Value, b.Groups[2].Value, valueIsHex))
                return a.Groups[1].Value + " (" + a.Groups[2].Value + " | " + b.Groups[2].Value + a.Groups[3].Value + ")";

            return null;
        }

        /// <summary>
        /// "{x=1655 y=222}" / "{x=0x00000677 y=0x000000de}" -> "{x=1655 (0x00000677) y=222 (0x000000de)}".
        /// Returns null for non-summaries and for summaries with more than MaxSummaryPairs numbers.
        /// </summary>
        internal static string MergeSummary(string value, string other, bool valueIsHex)
        {
            if (string.IsNullOrEmpty(value) || value.IndexOf('{') < 0)
                return null;
            return MergeAssignedNumbers(value, other, valueIsHex, MaxSummaryPairs);
        }

        /// <summary>
        /// Pairs up the integers that follow "=" in two renderings of the same text. The n-th
        /// number in <paramref name="text"/> is paired with the n-th number in
        /// <paramref name="other"/>; only those numbers are taken from <paramref name="other"/>,
        /// everything else (e.g. type names like "int[0x00000003]") comes from <paramref name="text"/>.
        /// </summary>
        internal static string MergeAssignedNumbers(string text, string other, bool textIsHex, int maxPairs)
        {
            if (string.IsNullOrEmpty(text) || string.IsNullOrEmpty(other) || text == other)
                return null;

            MatchCollection a = ArgumentValue.Matches(text);
            MatchCollection b = ArgumentValue.Matches(other);
            if (a.Count == 0 || a.Count != b.Count)
                return null;

            var merged = new StringBuilder();
            int pos = 0;
            int pairs = 0;
            for (int i = 0; i < a.Count; i++)
            {
                Match m = a[i];
                // Copy the text up to and including this number, then add " (other)".
                merged.Append(text, pos, m.Index + m.Length - pos);
                pos = m.Index + m.Length;
                if (m.Value != b[i].Value)
                {
                    // Two renderings that disagree anywhere are not trusted at all.
                    if (!RadixNumbers.IsPair(m.Value, b[i].Value, textIsHex) || ++pairs > maxPairs)
                        return null;
                    merged.Append(" (").Append(b[i].Value).Append(')');
                }
            }
            merged.Append(text, pos, text.Length - pos);
            return pairs > 0 ? merged.ToString() : null;
        }
    }
}

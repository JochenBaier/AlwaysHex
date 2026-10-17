// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;

namespace AlwaysHex
{
    /// <summary>
    /// Call Stack window: puts both radixes into the argument values of a frame name,
    /// e.g. "add(int lhs=100 (0x00000064), unsigned char rhs=200 (0xc8) 'È')". Only looks at text.
    /// </summary>
    internal static class FrameNameMerger
    {
        // "rhs='È'", "w=L'Z'", "c = u'x'": a char literal as the whole argument value.
        private static readonly Regex CharArgument = new Regex(
            @"(?<=(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*)(?<literal>(?:u8|u|U|L)?'(?:[^'\\]|\\.)*')(?=[,)])");

        /// <summary>
        /// Inserts the other radix after each integer argument value of a frame name, using
        /// the frame name rendered in the other radix. Returns null when nothing pairs up.
        /// </summary>
        internal static string MergeFrameName(string name, string other, bool nameIsHex)
        {
            return ValueMerger.MergeAssignedNumbers(name, other, nameIsHex, int.MaxValue);
        }

        /// <summary>True when the frame name has an argument whose value is a bare char literal.</summary>
        internal static bool HasCharArgument(string frameName)
        {
            return CharArgument.IsMatch(frameName);
        }

        /// <summary>
        /// Replaces bare char-literal argument values with the full value from
        /// <paramref name="argumentValues"/> ("rhs='È'" -> "rhs=200 (0xc8) 'È'") when that value
        /// ends with the same literal. Returns null when nothing was replaced.
        /// </summary>
        internal static string ReplaceCharArguments(string frameName, IDictionary<string, string> argumentValues)
        {
            if (string.IsNullOrEmpty(frameName) || argumentValues == null || argumentValues.Count == 0)
                return null;

            bool changed = false;
            string result = CharArgument.Replace(frameName, m =>
            {
                string value;
                if (argumentValues.TryGetValue(m.Groups["name"].Value, out value) &&
                    value.EndsWith(" " + m.Groups["literal"].Value, StringComparison.Ordinal))
                {
                    changed = true;
                    return value;
                }
                return m.Value;
            });
            return changed ? result : null;
        }
    }
}

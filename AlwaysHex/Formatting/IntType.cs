// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

namespace AlwaysHex
{
    /// <summary>Width in bits and signedness of an integer type (used by CSharpFormatter).</summary>
    internal struct IntType
    {
        public readonly int Bits;
        public readonly bool Signed;

        public IntType(int bits, bool signed)
        {
            Bits = bits;
            Signed = signed;
        }
    }
}

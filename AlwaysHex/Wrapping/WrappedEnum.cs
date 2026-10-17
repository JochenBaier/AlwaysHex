// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using Microsoft.VisualStudio.Debugger;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
    /// <summary>
    /// Data item ("hidden field") attached to enum contexts we hand out; holds the real EE's
    /// enum contexts in both radixes (<see cref="Other"/> is null when only one radix was
    /// evaluated). Both are closed when VS closes ours (OnClose).
    /// </summary>
    internal sealed class WrappedEnum : DkmDataItem
    {
        public readonly DkmEvaluationResultEnumContext Inner;
        public readonly DkmEvaluationResultEnumContext Other;

        public WrappedEnum(DkmEvaluationResultEnumContext inner, DkmEvaluationResultEnumContext other)
        {
            Inner = inner;
            Other = other;
        }

        protected override void OnClose()
        {
            Inner.Close();
            if (Other != null)
                Other.Close();
        }
    }
}

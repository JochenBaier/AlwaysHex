// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using Microsoft.VisualStudio.Debugger;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
    /// <summary>
    /// Data item ("hidden field") attached to results we hand out; points at the real EE's
    /// original result. When VS closes our result, the original is closed too (OnClose).
    /// </summary>
    internal sealed class WrappedResult : DkmDataItem
    {
        public readonly DkmEvaluationResult Inner;

        public WrappedResult(DkmEvaluationResult inner)
        {
            Inner = inner;
        }

        protected override void OnClose()
        {
            Inner.Close();
        }
    }
}

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
    /// <summary>
    /// Closes answers of the real EE that are not handed on to VS (the other-radix twins, or
    /// everything when the first answer failed) right away; VS would otherwise only release
    /// them when the debugger continues. Errors while closing are ignored.
    /// </summary>
    internal static class DkmCleanup
    {
        public static void CloseAll(DkmEvaluationResult[] results)
        {
            if (results == null)
                return;
            foreach (DkmEvaluationResult r in results)
                Close(r);
        }

        public static void Close(DkmEvaluationResult result)
        {
            try { if (result != null) result.Close(); } catch (Exception) { }
        }

        public static void Close(DkmEvaluationResultEnumContext enumContext)
        {
            try { if (enumContext != null) enumContext.Close(); } catch (Exception) { }
        }
    }
}

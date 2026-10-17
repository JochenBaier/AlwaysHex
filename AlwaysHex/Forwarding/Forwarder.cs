// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using Microsoft.VisualStudio.Debugger;

namespace AlwaysHex
{
    /// <summary>
    /// Sends requests to the real expression evaluator and waits for the answers.
    /// </summary>
    internal static class Forwarder
    {
        // Safety net against endless recursion: counts how deep we are inside our own
        // forwarded request on this thread. If a forwarded request ever comes back to us
        // (for example because a future VS version routes it differently), Forward throws
        // and VS shows an evaluation error instead of freezing.
        [ThreadStatic]
        private static int s_depth;

        /// <summary>
        /// Runs <paramref name="call"/> (and <paramref name="callOther"/>, if any) on a work
        /// list owned by this component and waits until both have answered. The calls are
        /// asynchronous Concord calls; Execute() runs the work list to completion, so the
        /// results are available when this method returns.
        /// </summary>
        /// <param name="call">Request with the user's radix; its answer is <paramref name="first"/>.</param>
        /// <param name="callOther">Request with the other radix, or null; its answer is
        /// <paramref name="second"/> (default value when null or failed).</param>
        /// <param name="errorCode">Reads the ErrorCode of an answer. An answer can be an error
        /// instead of a result, e.g. "canceled" when the user toggles Hexadecimal Display
        /// while the window is still being filled; reading any other property of such an
        /// answer throws. <paramref name="first"/> is returned as it is (the caller checks
        /// its ErrorCode); a failed <paramref name="second"/> is replaced by the default value.</param>
        /// <param name="errorResult">Builds an error answer (the result type's CreateErrorResult).
        /// It becomes <paramref name="first"/> when VS cancels while we are still waiting.</param>
        public static void Forward<T>(
            Action<DkmWorkList, DkmCompletionRoutine<T>> call,
            Action<DkmWorkList, DkmCompletionRoutine<T>> callOther,
            Func<T, int> errorCode,
            Func<Exception, T> errorResult,
            out T first,
            out T second)
            where T : struct
        {
            // We are already inside one of our own forwarded requests on this thread:
            // VS routed it back to us. Stop here instead of recursing forever.
            if (s_depth > 0)
                throw new InvalidOperationException("AlwaysHex: forwarded request was routed back to AlwaysHex");

            T a = default(T);
            T b = default(T);
            s_depth++;
            try
            {
                DkmWorkList own = DkmWorkList.Create(null);
                call(own, r => a = r);
                if (callOther != null)
                {
                    // A failing second request must not break the first one.
                    try
                    {
                        callOther(own, r => b = r);
                    }
                    catch (Exception)
                    {
                        // The value is shown in the user's radix only.
                    }
                }
                own.Execute();
            }
            catch (OperationCanceledException e)
            {
                // VS canceled the request while we were waiting (e.g. the user toggled
                // Hexadecimal Display while the Call Stack window was being filled). VS no
                // longer wants the answer: reply with a "canceled" error instead of letting
                // the exception leave AlwaysHex. (If VS cancels a little later, Execute()
                // returns normally and the answers themselves are "canceled" errors.)
                a = errorResult(e);
            }
            finally
            {
                s_depth--;
            }
            first = a;
            // Without the second answer the value is simply shown in the user's radix only.
            second = errorCode(b) == 0 ? b : default(T);
        }
    }
}

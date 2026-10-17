// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using System.Collections.Generic;
using Microsoft.VisualStudio.Debugger;
using Microsoft.VisualStudio.Debugger.CallStack;
using Microsoft.VisualStudio.Debugger.ComponentInterfaces;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
    /// <summary>
    /// Call Stack window part of the component (see AlwaysHexEvaluator.cs for the overview).
    /// </summary>
    public sealed partial class AlwaysHexEvaluator : IDkmLanguageFrameDecoder
    {
        /// <summary>
        /// Text of one Call Stack row, e.g. "add(int lhs=100, unsigned char rhs='È')".
        /// With "Show Parameter Values" on, the argument values get both radixes:
        /// "add(int lhs=100 (0x00000064), unsigned char rhs=200 (0xc8) 'È')".
        /// </summary>
        void IDkmLanguageFrameDecoder.GetFrameName(
            DkmInspectionContext inspectionContext,
            DkmWorkList workList,
            DkmStackWalkFrame frame,
            DkmVariableInfoFlags argumentFlags,
            DkmCompletionRoutine<DkmGetFrameNameAsyncResult> completionRoutine)
        {
            // Only frame names that contain argument values need a second rendering.
            // The frame name has no per-value type to format C# locally, so both languages
            // evaluate twice here; argument values never run property getters.
            bool values = (argumentFlags & DkmVariableInfoFlags.Values) != 0;
            ForwardingContexts c = ForwardingContexts.Create(inspectionContext, values, allowLocalFormat: false);

            DkmGetFrameNameAsyncResult orig, other;
            Forwarder.Forward(
                (wl, cr) => c.Same.GetFrameName(wl, frame, argumentFlags, cr),
                c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmGetFrameNameAsyncResult>>)
                    ((wl, cr) => c.Other.GetFrameName(wl, frame, argumentFlags, cr)),
                r => r.ErrorCode,
                DkmGetFrameNameAsyncResult.CreateErrorResult,
                out orig, out other);

            // An error answer (e.g. "canceled") is passed on; reading its FrameName would throw.
            if (orig.ErrorCode != 0)
            {
                completionRoutine(orig);
                return;
            }

            // Pair the numbers after "=" from both renderings: "lhs=100" + "lhs=0x00000064".
            // (A failed other answer arrives as the default value: FrameName null, no merge.)
            string merged = FrameNameMerger.MergeFrameName(orig.FrameName, other.FrameName, inspectionContext.Radix == 16);

            // The C++ EE prints char arguments as the bare literal ("rhs='È'"), with no number
            // in either radix: take those values from the frame's arguments instead.
            string text = merged ?? orig.FrameName;
            if (values && c.Other != null && text != null && FrameNameMerger.HasCharArgument(text))
            {
                string withChars = FrameNameMerger.ReplaceCharArguments(
                    text, GetArgumentValues(c, frame, inspectionContext.Radix == 16));
                if (withChars != null)
                    merged = withChars;
            }

            completionRoutine(merged == null ? orig : new DkmGetFrameNameAsyncResult(merged));
        }

        /// <summary>The return type shown for a frame. Contains no values: forwarded unchanged.</summary>
        void IDkmLanguageFrameDecoder.GetFrameReturnType(
            DkmInspectionContext inspectionContext,
            DkmWorkList workList,
            DkmStackWalkFrame frame,
            DkmCompletionRoutine<DkmGetFrameReturnTypeAsyncResult> completionRoutine)
        {
            ForwardingContexts c = ForwardingContexts.Create(inspectionContext, false);

            DkmGetFrameReturnTypeAsyncResult result, unused;
            Forwarder.Forward((wl, cr) => c.Same.GetFrameReturnType(wl, frame, cr), null,
                r => r.ErrorCode, DkmGetFrameReturnTypeAsyncResult.CreateErrorResult, out result, out unused);
            completionRoutine(result);
        }

        /// <summary>Argument name -> value in both radixes ("200 (0xc8) 'È'"), as Locals shows it.</summary>
        private static Dictionary<string, string> GetArgumentValues(ForwardingContexts c, DkmStackWalkFrame frame, bool radixIsHex)
        {
            var values = new Dictionary<string, string>();
            DkmGetFrameArgumentsAsyncResult orig, other;
            Forwarder.Forward(
                (wl, cr) => c.Same.GetFrameArguments(wl, frame, cr),
                (wl, cr) => c.Other.GetFrameArguments(wl, frame, cr),
                r => r.ErrorCode,
                DkmGetFrameArgumentsAsyncResult.CreateErrorResult,
                out orig, out other);

            // An error answer (e.g. "canceled") has no arguments; reading them would throw.
            if (orig.ErrorCode != 0)
            {
                DkmCleanup.CloseAll(other.Arguments);
                return values;
            }

            if (orig.Arguments != null && other.Arguments != null)
            {
                for (int i = 0; i < orig.Arguments.Length && i < other.Arguments.Length; i++)
                {
                    var o = orig.Arguments[i] as DkmSuccessEvaluationResult;
                    var x = other.Arguments[i] as DkmSuccessEvaluationResult;
                    if (o == null || x == null || o.Name != x.Name || values.ContainsKey(o.Name))
                        continue;
                    string value = ValueMerger.MergeValue(o.Value, x.Value, radixIsHex);
                    if (value != null)
                        values.Add(o.Name, value);
                }
            }

            // These results were only needed for their strings; nobody else holds them.
            DkmCleanup.CloseAll(orig.Arguments);
            DkmCleanup.CloseAll(other.Arguments);
            return values;
        }
    }
}

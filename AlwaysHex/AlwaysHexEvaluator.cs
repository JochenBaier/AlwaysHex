// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using Microsoft.VisualStudio.Debugger;
using Microsoft.VisualStudio.Debugger.CallStack;
using Microsoft.VisualStudio.Debugger.ComponentInterfaces;
using Microsoft.VisualStudio.Debugger.Evaluation;

// =====================================================================================
// WHAT ALWAYSHEX DOES
// =====================================================================================
//
// Visual Studio shows a debugged variable either in decimal ("100") or in hex
// ("0x00000064"), depending on the "Hexadecimal Display" toggle. This component makes
// the debugger show both at once: "100 (0x00000064)", or "0x00000064 (100)" when hex
// display is on. The radix the user picked always comes first.
//
// It works for C/C++ and C# in data tips, Watch, Locals, Autos, struct members and the
// Call Stack window.
//
// -------------------------------------------------------------------------------------
// WHERE THE CODE IS
// -------------------------------------------------------------------------------------
//
//  AlwaysHexEvaluator.cs            Entry point for Watch, Locals, Autos, data tips
//  AlwaysHexEvaluator.CallStack.cs  Entry point for the Call Stack window
//  Forwarding\                      Asking the built-in expression evaluators
//    ForwardingContexts.cs            the two request contexts (user's radix, other radix)
//    Forwarder.cs                     running the requests, recursion guard
//  Wrapping\                        Handing answers back to Visual Studio
//    ResultWrapper.cs                 re-creating results and lists, unwrapping
//    WrappedResult.cs, WrappedEnum.cs the data items that point to the original objects
//    DkmCleanup.cs                    closing answers that are not handed on
//  Formatting\                      Pure text work, no debugger calls
//    ValueMerger.cs                   C/C++: "100" + "0x00000064" -> "100 (0x00000064)"
//    FrameNameMerger.cs               Call Stack texts, char arguments
//    RadixNumbers.cs                  do a decimal and a hex number agree?
//    CSharpFormatter.cs, IntType.cs   C#: compute the other radix from value and type
//    FormatSpecifier.cs               detect "a,x", "a,d" in Watch expressions
//
// -------------------------------------------------------------------------------------
// VISUAL STUDIO DEBUGGER TERMS USED IN THIS CODE ("Concord" is the VS debug engine)
// -------------------------------------------------------------------------------------
//
//  Component            A plug-in for the debug engine. Each component has a numeric
//                       "level". When VS needs something, it asks the component with the
//                       highest level that matches the request first. Our level is
//                       9,993,000, set in AlwaysHex.vsdconfigxml.
//
//  Expression           The built-in part of VS that turns "a" or "pt.x" into a value
//  evaluator (EE)       string. The C++ EE is "CppEE::CCppExprEval", the C# one runs inside
//                       "VSDebugEngine.ManagedEE". Both sit at level 9,992,000, just below
//                       us, so every request reaches us first.
//
//  Inspection context   The settings for one request: which thread, which language,
//  (DkmInspectionContext) and the radix (10 or 16). We create copies of it to ask the EE
//                       for the other radix.
//
//  Evaluation result    One row in Watch/Locals: name, value string, type, and a few
//  (DkmEvaluationResult) flags. "Success" and "failed" results are the common kinds.
//
//  Enum context         A handle for "the remaining rows" of a big list, for example the
//  (DkmEvaluationResultEnumContext) children of a struct or all locals of a function.
//                       VS asks for the rows in chunks via GetItems.
//
//  Work list and        Most calls are asynchronous: the caller passes a work list and a
//  completion routine   completion routine; the answer arrives in the completion routine.
//
//  Data item            A small object that a component can attach to any Concord object,
//  (DkmDataItem)        like a hidden extra field. We use it to remember which original
//                       EE object belongs to an object we created.
//
// -------------------------------------------------------------------------------------
// HOW A REQUEST FLOWS (example: the user hovers over "a" in C++)
// -------------------------------------------------------------------------------------
//
//  1. VS calls our EvaluateExpression("a") with the user's radix, say 10.
//  2. We ask the real C++ EE twice (see Forwarder.Forward):
//       - once in radix 10                      -> "100"
//       - once in radix 16, side effects off    -> "0x00000064"
//  3. ValueMerger.MergeValue combines the two   -> "100 (0x00000064)".
//  4. We create a new result with the merged string and hand it to VS (see
//     ResultWrapper.Wrap). A data item on it remembers the C++ EE's original result.
//  5. When the user later expands, edits or scrolls that row, VS calls us again with our
//     result; ResultWrapper.Unwrap finds the original and we pass the request on.
//
//  C# is different in step 2: we ask the C# EE only once and compute the other radix
//  ourselves from the value and its type name (see CSharpFormatter). C# has no typedefs,
//  so "short" always means 16-bit signed. That way property getters, which C# runs to
//  show a property's value, never run twice.
//
// -------------------------------------------------------------------------------------
// THE ROUTING TRICK (why requests do not loop back to us)
// -------------------------------------------------------------------------------------
//
//  The obvious approach is "call the same API again and VS will pass it to the next
//  component below us". That does not work for expression evaluators: VS sends such a
//  call straight back to us, which recursed until VS froze.
//
//  Instead, our forwarded requests use an inspection context whose language is the same
//  (C++ or C#) but whose "compiler vendor id" is a private GUID
//  (ForwardingContexts.ForwardVendorId):
//    - The built-in EEs only check the runtime and language id, so they accept it.
//    - Our component additionally requires the Microsoft vendor id (vsdconfigxml), so VS
//      does not route it to us.
//  Everything we return to VS is re-created with the caller's original (Microsoft)
//  context, so follow-up requests from the UI come back to us, not directly to the EE.
//
//  This relies on undocumented behavior of the built-in EEs (verified with VS 2022 17.14
//  and VS 2026 18.11).
// =====================================================================================

namespace AlwaysHex
{
    /// <summary>
    /// The debug engine component registered in AlwaysHex.vsdconfigxml. VS creates one instance
    /// and calls the interface methods; the class keeps no state of its own (per-object state
    /// lives in data items). This file: Watch, Locals, Autos and data tips.
    /// AlwaysHexEvaluator.CallStack.cs: the Call Stack window.
    /// </summary>
    public sealed partial class AlwaysHexEvaluator : IDkmLanguageExpressionEvaluator
    {
        // =================================================================================
        // IDkmLanguageExpressionEvaluator: Watch, Locals, Autos, data tips
        // =================================================================================
        //
        // All methods follow the same pattern:
        //   1. Build the forwarding contexts (ForwardingContexts.Create): same radix + other radix.
        //   2. Ask the real EE in both radixes (Forwarder.Forward).
        //   3. Re-create the answers for VS with merged value strings (ResultWrapper.Wrap /
        //      WrapAll / WrapEnum) and pass them to the completion routine.
        // If the real EE reports an error, its answer is passed on unchanged.

        /// <summary>
        /// Evaluates one expression: data tips, Watch window entries, Immediate window.
        /// Expressions with an explicit format specifier ("a,x", "a,d") are evaluated once
        /// and left alone, because the user asked for one specific format.
        /// </summary>
        void IDkmLanguageExpressionEvaluator.EvaluateExpression(
            DkmInspectionContext inspectionContext,
            DkmWorkList workList,
            DkmLanguageExpression expression,
            DkmStackWalkFrame stackFrame,
            DkmCompletionRoutine<DkmEvaluateExpressionAsyncResult> completionRoutine)
        {
            bool dual = !FormatSpecifier.HasFormatSpecifier(expression.Text);
            ForwardingContexts c = ForwardingContexts.Create(inspectionContext, dual);

            // The expression object also carries a language; give the EE one with our
            // private vendor id, matching the forwarding context.
            DkmLanguageExpression fwdExpression = DkmLanguageExpression.Create(
                c.Same.Language, expression.CompilationFlags, expression.Text, null);

            DkmEvaluateExpressionAsyncResult orig, other;
            Forwarder.Forward(
                (wl, cr) => c.Same.EvaluateExpression(wl, fwdExpression, stackFrame, cr),
                c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmEvaluateExpressionAsyncResult>>)
                    ((wl, cr) => c.Other.EvaluateExpression(wl, fwdExpression, stackFrame, cr)),
                r => r.ErrorCode,
                DkmEvaluateExpressionAsyncResult.CreateErrorResult,
                out orig, out other);

            // Check ErrorCode first: reading ResultObject of an error answer throws.
            if (orig.ErrorCode != 0 || orig.ResultObject == null)
            {
                DkmCleanup.Close(other.ResultObject);
                completionRoutine(orig);
                return;
            }
            completionRoutine(new DkmEvaluateExpressionAsyncResult(
                ResultWrapper.Wrap(orig.ResultObject, other.ResultObject, inspectionContext, dual)));
        }

        /// <summary>
        /// Expands a row (struct members, array elements, class fields). Returns the first
        /// <paramref name="initialRequestSize"/> children plus an enum context for the rest.
        /// <paramref name="result"/> is one of our wrapped results, so it is unwrapped first.
        /// </summary>
        void IDkmLanguageExpressionEvaluator.GetChildren(
            DkmEvaluationResult result,
            DkmWorkList workList,
            int initialRequestSize,
            DkmInspectionContext inspectionContext,
            DkmCompletionRoutine<DkmGetChildrenAsyncResult> completionRoutine)
        {
            DkmEvaluationResult inner = ResultWrapper.Unwrap(result);
            ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

            DkmGetChildrenAsyncResult orig, other;
            Forwarder.Forward(
                (wl, cr) => inner.GetChildren(wl, initialRequestSize, c.Same, cr),
                c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmGetChildrenAsyncResult>>)
                    ((wl, cr) => inner.GetChildren(wl, initialRequestSize, c.Other, cr)),
                r => r.ErrorCode,
                DkmGetChildrenAsyncResult.CreateErrorResult,
                out orig, out other);

            if (orig.ErrorCode != 0 || orig.InitialChildren == null)
            {
                DkmCleanup.CloseAll(other.InitialChildren);
                DkmCleanup.Close(other.EnumContext);
                completionRoutine(orig);
                return;
            }
            completionRoutine(new DkmGetChildrenAsyncResult(
                ResultWrapper.WrapAll(orig.InitialChildren, other.InitialChildren, inspectionContext),
                ResultWrapper.WrapEnum(orig.EnumContext, other.EnumContext, inspectionContext)));
        }

        /// <summary>
        /// Fills the Locals window: returns an enum context; the rows themselves are then
        /// fetched through GetItems.
        /// </summary>
        void IDkmLanguageExpressionEvaluator.GetFrameLocals(
            DkmInspectionContext inspectionContext,
            DkmWorkList workList,
            DkmStackWalkFrame stackFrame,
            DkmCompletionRoutine<DkmGetFrameLocalsAsyncResult> completionRoutine)
        {
            ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

            DkmGetFrameLocalsAsyncResult orig, other;
            Forwarder.Forward(
                (wl, cr) => c.Same.GetFrameLocals(wl, stackFrame, cr),
                c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmGetFrameLocalsAsyncResult>>)
                    ((wl, cr) => c.Other.GetFrameLocals(wl, stackFrame, cr)),
                r => r.ErrorCode,
                DkmGetFrameLocalsAsyncResult.CreateErrorResult,
                out orig, out other);

            if (orig.ErrorCode != 0 || orig.EnumContext == null)
            {
                DkmCleanup.Close(other.EnumContext);
                completionRoutine(orig);
                return;
            }
            completionRoutine(new DkmGetFrameLocalsAsyncResult(
                ResultWrapper.WrapEnum(orig.EnumContext, other.EnumContext, inspectionContext)));
        }

        /// <summary>The arguments of a function, e.g. for the Locals window of a frame.</summary>
        void IDkmLanguageExpressionEvaluator.GetFrameArguments(
            DkmInspectionContext inspectionContext,
            DkmWorkList workList,
            DkmStackWalkFrame frame,
            DkmCompletionRoutine<DkmGetFrameArgumentsAsyncResult> completionRoutine)
        {
            ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

            DkmGetFrameArgumentsAsyncResult orig, other;
            Forwarder.Forward(
                (wl, cr) => c.Same.GetFrameArguments(wl, frame, cr),
                c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmGetFrameArgumentsAsyncResult>>)
                    ((wl, cr) => c.Other.GetFrameArguments(wl, frame, cr)),
                r => r.ErrorCode,
                DkmGetFrameArgumentsAsyncResult.CreateErrorResult,
                out orig, out other);

            if (orig.ErrorCode != 0 || orig.Arguments == null)
            {
                DkmCleanup.CloseAll(other.Arguments);
                completionRoutine(orig);
                return;
            }
            completionRoutine(new DkmGetFrameArgumentsAsyncResult(
                ResultWrapper.WrapAll(orig.Arguments, other.Arguments, inspectionContext)));
        }

        /// <summary>
        /// Fetches rows <paramref name="startIndex"/>.. from an enum context that we handed
        /// out earlier (GetChildren, GetFrameLocals). The WrappedEnum data item on it holds
        /// the real EE's enum contexts for both radixes.
        /// </summary>
        void IDkmLanguageExpressionEvaluator.GetItems(
            DkmEvaluationResultEnumContext enumContext,
            DkmWorkList workList,
            int startIndex,
            int count,
            DkmCompletionRoutine<DkmEvaluationEnumAsyncResult> completionRoutine)
        {
            WrappedEnum wrapped = enumContext.GetDataItem<WrappedEnum>();
            if (wrapped == null)
            {
                // Not created by us. Forwarding it would come straight back here, so fail.
                completionRoutine(DkmEvaluationEnumAsyncResult.CreateErrorResult(
                    new InvalidOperationException("AlwaysHex: unknown enum context")));
                return;
            }

            DkmEvaluationEnumAsyncResult orig, other;
            Forwarder.Forward(
                (wl, cr) => wrapped.Inner.GetItems(wl, startIndex, count, cr),
                wrapped.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmEvaluationEnumAsyncResult>>)
                    ((wl, cr) => wrapped.Other.GetItems(wl, startIndex, count, cr)),
                r => r.ErrorCode,
                DkmEvaluationEnumAsyncResult.CreateErrorResult,
                out orig, out other);

            if (orig.ErrorCode != 0 || orig.Items == null)
            {
                DkmCleanup.CloseAll(other.Items);
                completionRoutine(orig);
                return;
            }
            completionRoutine(new DkmEvaluationEnumAsyncResult(
                ResultWrapper.WrapAll(orig.Items, other.Items, enumContext.InspectionContext)));
        }

        /// <summary>
        /// "Edit Value" in Watch/Locals. The user edits the plain value (EditableValue is
        /// kept from the original result), so the real EE can parse it as usual.
        /// </summary>
        void IDkmLanguageExpressionEvaluator.SetValueAsString(
            DkmEvaluationResult result, string value, int timeout, out string errorText)
        {
            ResultWrapper.Unwrap(result).SetValueAsString(value, timeout, out errorText);
        }

        /// <summary>The full text behind the string visualizers (magnifying glass icon).</summary>
        string IDkmLanguageExpressionEvaluator.GetUnderlyingString(DkmEvaluationResult result)
        {
            return ResultWrapper.Unwrap(result).GetUnderlyingString();
        }
    }
}

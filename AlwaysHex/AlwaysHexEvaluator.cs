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
// It works for C/C++ (this component) and C# (AlwaysHexClrFormatter.cs, see below) in data
// tips, Watch, Locals, Autos, struct members and the Call Stack window.
//
// -------------------------------------------------------------------------------------
// WHERE THE CODE IS
// -------------------------------------------------------------------------------------
//
//  AlwaysHexEvaluator.cs            Entry point for Watch, Locals, Autos, data tips
//  AlwaysHexEvaluator.CallStack.cs  Entry point for the Call Stack window
//  AlwaysHexEvaluator.ResultFeatures.cs  Break When Value Changes, pinned members, Object IDs
//  AlwaysHexClrFormatter.cs         C#: a separate, server-side component (see below)
//  Forwarding\                     Asking the built-in expression evaluators
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
//    CSharpFormatter.cs, IntType.cs   C#: compute the other radix from value and type name
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
//  evaluator (EE)       string. The C++ EE is "CppEE::CCppExprEval" at level 9,992,000,
//                       just below us, so every C/C++ request reaches us first.
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
//  C# works differently, without replacing anything: AlwaysHexClrFormatter.cs is a second,
//  server-side component (level 63,100) right above the C# result provider (63,000). It
//  adds the other radix where the C# value text is produced, so Visual Studio keeps the C#
//  result provider's own results. Replacing them would break .NET visualizers, which need
//  the provider's private data and can only be served on the server side.
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
//  (C or C++) but whose "compiler vendor id" is a private GUID
//  (ForwardingContexts.ForwardVendorId):
//    - The built-in EE only checks the runtime and language id, so it accepts it.
//    - Our component additionally requires the Microsoft vendor id (vsdconfigxml), so VS
//      does not route it to us.
//  Everything we return to VS is re-created with the caller's original (Microsoft)
//  context, so follow-up requests from the UI come back to us, not directly to the EE.
//
//  Safety net: if VS ever routes a forwarded request back to us anyway, its context carries
//  our private vendor id. ForwardingContexts.ThrowIfForwarded detects that on any thread and
//  the request gets an error answer (Answer) instead of being forwarded again. Should a future
//  version re-create the context with Microsoft's vendor id on the way, Forwarder's depth
//  limit (per thread) and in-flight cap (whole process) end the loop with an error, and its
//  failure latch makes the requests still queued in that loop fail at once instead of starting
//  it anew. None of this can make a downstream component answer that never answers.
//
//  This relies on undocumented behavior of the built-in EEs (verified with VS 2022 17.14
//  and VS 2026 18.11).
// =====================================================================================

namespace AlwaysHex
{
  /// <summary>
  /// The C/C++ debug engine component registered in AlwaysHex.vsdconfigxml (native code only).
  /// VS creates one instance and calls the interface methods; the class keeps no state of its
  /// own (per-object state lives in data items). This file: Watch, Locals, Autos, data tips and
  /// return values. AlwaysHexEvaluator.CallStack.cs: the Call Stack window.
  /// AlwaysHexEvaluator.ResultFeatures.cs: features VS calls on a shown row (data breakpoints,
  /// pinned members, Object IDs).
  /// </summary>
  public sealed partial class AlwaysHexEvaluator :
      IDkmLanguageExpressionEvaluator,
      IDkmLanguageReturnValueEvaluator,
      IDkmLanguageReturnValueEvaluator2
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
    // If the real EE reports an error, its answer is passed on unchanged. Steps 1-3 run
    // inside Answer, which turns an exception of our own into an error answer.

    /// <summary>
    /// Evaluates one expression: data tips, Watch window entries, Immediate window.
    /// Expressions with an explicit format specifier ("a,x", "a,d") are evaluated once
    /// and left alone, because the user asked for one specific format.
    /// </summary>
    void IDkmLanguageExpressionEvaluator.EvaluateExpression(DkmInspectionContext inspectionContext, DkmWorkList workList,
        DkmLanguageExpression expression, DkmStackWalkFrame stackFrame,
        DkmCompletionRoutine<DkmEvaluateExpressionAsyncResult> completionRoutine)
    {
      Answer(completionRoutine, DkmEvaluateExpressionAsyncResult.CreateErrorResult, () =>
      {
        bool dual = !FormatSpecifier.HasFormatSpecifier(expression.Text);
        DebugLog.Use(inspectionContext);

        if (DebugLog.Enabled)
        {
          DebugLog.Write("EvaluateExpression " + DebugLog.Show(expression.Text) + " (data tip, Watch, Immediate), radix " +
                  inspectionContext.Radix + (dual ? "" : ": format specifier, asked once and left alone"));
        }

        ForwardingContexts c = ForwardingContexts.Create(inspectionContext, dual);

        // The expression object also carries a language; give the EE ones with our
        // private vendor id, matching the forwarding contexts. Concord requires the
        // expression's compilation flags to agree with the context's evaluation flags, so
        // the other-radix request (no side effects, no function calls) gets its own
        // expression. We created both, so we close both ("the caller is responsible for
        // closing the created object", DkmLanguageExpression.Create).
        DkmLanguageExpression fwdExpression = null;
        DkmLanguageExpression fwdOtherExpression = null;
        DkmEvaluateExpressionAsyncResult orig, other;

        try
        {
          fwdExpression = DkmLanguageExpression.Create(c.Same.Language, expression.CompilationFlags, expression.Text, null);

          if (c.Other != null)
          {
            fwdOtherExpression = DkmLanguageExpression.Create(c.Other.Language, expression.CompilationFlags | ForwardingContexts.OtherFlags,
                expression.Text, null);
          }

          Forwarder.Forward((wl, cr) => c.Same.EvaluateExpression(wl, fwdExpression, stackFrame, cr),
              fwdOtherExpression == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmEvaluateExpressionAsyncResult>>)
                  ((wl, cr) => c.Other.EvaluateExpression(wl, fwdOtherExpression, stackFrame, cr)), r => r.ErrorCode,
              DkmEvaluateExpressionAsyncResult.CreateErrorResult, out orig, out other);
        }
        finally
        {
          DkmCleanup.Close(fwdExpression);
          DkmCleanup.Close(fwdOtherExpression);
        }

        // Check ErrorCode first: reading ResultObject of an error answer throws.
        if (orig.ErrorCode != 0 || orig.ResultObject == null)
        {
          if (DebugLog.Enabled)
          {
            DebugLog.Write("  C++ EE answered with an error (0x" + orig.ErrorCode.ToString("x8") + "): passed on unchanged");
          }

          DkmCleanup.Close(other.ResultObject);
          return orig;
        }

        if (DebugLog.Enabled)
        {
          DebugLog.Write("  C++ EE answers: " + DebugLog.Show(orig.ResultObject) + "; other radix: " +
                  (c.Other == null ? "not asked" : DebugLog.Show(other.ResultObject)));
        }

        return new DkmEvaluateExpressionAsyncResult(ResultWrapper.Wrap(orig.ResultObject, other.ResultObject, inspectionContext));
      });
    }

    /// <summary>
    /// Expands a row (struct members, array elements, class fields). Returns the first
    /// <paramref name="initialRequestSize"/> children plus an enum context for the rest.
    /// <paramref name="result"/> is normally one of our wrapped results, so it is unwrapped
    /// first. A result we did not create is forwarded as it is; should VS route that back
    /// to us, ForwardingContexts.Create sees our vendor id and the row gets an error.
    /// </summary>
    void IDkmLanguageExpressionEvaluator.GetChildren(DkmEvaluationResult result, DkmWorkList workList, int initialRequestSize,
        DkmInspectionContext inspectionContext, DkmCompletionRoutine<DkmGetChildrenAsyncResult> completionRoutine)
    {
      Answer(completionRoutine, DkmGetChildrenAsyncResult.CreateErrorResult, () =>
      {
        DkmEvaluationResult inner = ResultWrapper.Unwrap(result);
        DebugLog.Use(inspectionContext);

        if (DebugLog.Enabled)
        {
          DebugLog.Write("GetChildren of " + DebugLog.Show(inner) + " (row expanded), first " + initialRequestSize + " children" +
                  (ReferenceEquals(inner, result) ? " - not one of our results" : ""));
        }

        ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

        DkmGetChildrenAsyncResult orig, other;
        Forwarder.Forward((wl, cr) => inner.GetChildren(wl, initialRequestSize, c.Same, cr),
            c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmGetChildrenAsyncResult>>)
                ((wl, cr) => inner.GetChildren(wl, initialRequestSize, c.Other, cr)), r => r.ErrorCode,
            DkmGetChildrenAsyncResult.CreateErrorResult, out orig, out other);

        if (orig.ErrorCode != 0)
        {
          DkmCleanup.CloseAll(other.InitialChildren);
          DkmCleanup.Close(other.EnumContext);
          return orig;
        }

        // No initial children (e.g. initialRequestSize 0) still needs the enum context
        // wrapped; passing the EE's own one on would bypass us for all remaining rows.
        DkmEvaluationResult[] children = ResultWrapper.WrapAll(orig.InitialChildren ?? new DkmEvaluationResult[0], other.InitialChildren,
            inspectionContext);
        DkmEvaluationResultEnumContext enumContext;

        try
        {
          enumContext = ResultWrapper.WrapEnum(orig.EnumContext, other.EnumContext, inspectionContext);
        }
        catch (Exception)
        {
          // The children are not handed to VS: close them (closing one of ours closes
          // the EE's original too, WrappedResult.OnClose). WrapEnum closed its own.
          DkmCleanup.CloseAll(children);
          throw;
        }

        if (DebugLog.Enabled)
        {
          DebugLog.Write("  -> " + children.Length + " children now, " +
              (enumContext != null ? enumContext.Count + " in all (the rest via GetItems)" : "no more"));
        }

        return new DkmGetChildrenAsyncResult(children, enumContext);
      });
    }

    /// <summary>
    /// Fills the Locals window: returns an enum context; the rows themselves are then
    /// fetched through GetItems.
    /// </summary>
    void IDkmLanguageExpressionEvaluator.GetFrameLocals(DkmInspectionContext inspectionContext, DkmWorkList workList,
        DkmStackWalkFrame stackFrame, DkmCompletionRoutine<DkmGetFrameLocalsAsyncResult> completionRoutine)
    {
      Answer(completionRoutine, DkmGetFrameLocalsAsyncResult.CreateErrorResult, () =>
      {
        DebugLog.Use(inspectionContext);

        if (DebugLog.Enabled)
        {
          DebugLog.Write("GetFrameLocals (Locals window), radix " + inspectionContext.Radix);
        }

        ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

        DkmGetFrameLocalsAsyncResult orig, other;
        Forwarder.Forward((wl, cr) => c.Same.GetFrameLocals(wl, stackFrame, cr),
            c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmGetFrameLocalsAsyncResult>>)
                ((wl, cr) => c.Other.GetFrameLocals(wl, stackFrame, cr)), r => r.ErrorCode, DkmGetFrameLocalsAsyncResult.CreateErrorResult,
            out orig, out other);

        if (orig.ErrorCode != 0 || orig.EnumContext == null)
        {
          DkmCleanup.Close(other.EnumContext);
          return orig;
        }

        return new DkmGetFrameLocalsAsyncResult(ResultWrapper.WrapEnum(orig.EnumContext, other.EnumContext, inspectionContext));
      });
    }

    /// <summary>The arguments of a function, e.g. for the Locals window of a frame.</summary>
    void IDkmLanguageExpressionEvaluator.GetFrameArguments(DkmInspectionContext inspectionContext, DkmWorkList workList,
        DkmStackWalkFrame frame, DkmCompletionRoutine<DkmGetFrameArgumentsAsyncResult> completionRoutine)
    {
      Answer(completionRoutine, DkmGetFrameArgumentsAsyncResult.CreateErrorResult, () =>
      {
        DebugLog.Use(inspectionContext);

        if (DebugLog.Enabled)
        {
          DebugLog.Write("GetFrameArguments, radix " + inspectionContext.Radix);
        }

        ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

        DkmGetFrameArgumentsAsyncResult orig, other;
        Forwarder.Forward((wl, cr) => c.Same.GetFrameArguments(wl, frame, cr),
            c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmGetFrameArgumentsAsyncResult>>)
                ((wl, cr) => c.Other.GetFrameArguments(wl, frame, cr)), r => r.ErrorCode, DkmGetFrameArgumentsAsyncResult.CreateErrorResult,
            out orig, out other);

        if (orig.ErrorCode != 0 || orig.Arguments == null)
        {
          DkmCleanup.CloseAll(other.Arguments);
          return orig;
        }

        return new DkmGetFrameArgumentsAsyncResult(ResultWrapper.WrapAll(orig.Arguments, other.Arguments, inspectionContext));
      });
    }

    /// <summary>
    /// Fetches rows <paramref name="startIndex"/>.. from an enum context that we handed
    /// out earlier (GetChildren, GetFrameLocals). The WrappedEnum data item on it holds
    /// the real EE's enum contexts for both radixes.
    /// </summary>
    void IDkmLanguageExpressionEvaluator.GetItems(DkmEvaluationResultEnumContext enumContext, DkmWorkList workList, int startIndex,
        int count, DkmCompletionRoutine<DkmEvaluationEnumAsyncResult> completionRoutine)
    {
      Answer(completionRoutine, DkmEvaluationEnumAsyncResult.CreateErrorResult, () =>
      {
        WrappedEnum wrapped = enumContext.GetDataItem<WrappedEnum>();
        DebugLog.Use(enumContext.InspectionContext);

        if (DebugLog.Enabled)
        {
          DebugLog.Write("GetItems rows " + startIndex + ".." + (startIndex + count - 1) + " of " + enumContext.Count +
                  (wrapped == null ? " - not one of our enum contexts: error" : ""));
        }

        if (wrapped == null)
        {
          // Not created by us (or one of the EE's own, routed back). Forwarding it
          // would come straight back here, so fail.
          return DkmEvaluationEnumAsyncResult.CreateErrorResult(new InvalidOperationException("AlwaysHex: unknown enum context"));
        }

        DkmEvaluationEnumAsyncResult orig, other;
        Forwarder.Forward((wl, cr) => wrapped.Inner.GetItems(wl, startIndex, count, cr),
            wrapped.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmEvaluationEnumAsyncResult>>)
                ((wl, cr) => wrapped.Other.GetItems(wl, startIndex, count, cr)), r => r.ErrorCode,
            DkmEvaluationEnumAsyncResult.CreateErrorResult, out orig, out other);

        if (orig.ErrorCode != 0 || orig.Items == null)
        {
          DkmCleanup.CloseAll(other.Items);
          return orig;
        }

        return new DkmEvaluationEnumAsyncResult(ResultWrapper.WrapAll(orig.Items, other.Items, enumContext.InspectionContext));
      });
    }

    /// <summary>
    /// "Edit Value" in Watch/Locals. The user edits the plain value (EditableValue is
    /// kept from the original result), so the real EE can parse it as usual.
    /// </summary>
    void IDkmLanguageExpressionEvaluator.SetValueAsString(DkmEvaluationResult result, string value, int timeout, out string errorText)
    {
      WrappedResult wrapped = result.GetDataItem<WrappedResult>();

      if (wrapped == null)
      {
        // Not created by us. A result that reaches us has the Microsoft vendor id, so
        // calling it again would come straight back here: endless recursion, VS crash.
        errorText = "AlwaysHex: unknown evaluation result";
        return;
      }

      // Synchronous: an exception of the EE is passed on as it is (see ResultFeatures).
      wrapped.Inner.SetValueAsString(value, timeout, out errorText);
    }

    /// <summary>The full text behind the string visualizers (magnifying glass icon).</summary>
    string IDkmLanguageExpressionEvaluator.GetUnderlyingString(DkmEvaluationResult result)
    {
      // Not created by us: calling it again would recurse (see SetValueAsString).
      WrappedResult wrapped = result.GetDataItem<WrappedResult>();
      return wrapped != null ? wrapped.Inner.GetUnderlyingString() : null;
    }

    // =================================================================================
    // IDkmLanguageReturnValueEvaluator(2): "f returned" rows in Autos
    // =================================================================================
    //
    // VS asks the EE directly for the values a function returned while stepping. Without
    // these two methods the EE would create those rows with the caller's (Microsoft)
    // context, so expanding, editing or pinning them would reach us with a result we did
    // not create. Forwarded and wrapped like EvaluateExpression.

    void IDkmLanguageReturnValueEvaluator.EvaluateReturnValue(DkmInspectionContext inspectionContext, DkmWorkList workList,
        DkmStackWalkFrame stackFrame, DkmRawReturnValue rawReturnValue,
        DkmCompletionRoutine<DkmEvaluateReturnValueAsyncResult> completionRoutine)
    {
      Answer(completionRoutine, DkmEvaluateReturnValueAsyncResult.CreateErrorResult, () =>
      {
        DebugLog.Use(inspectionContext);

        if (DebugLog.Enabled)
        {
          DebugLog.Write("EvaluateReturnValue (Autos 'returned' row), radix " + inspectionContext.Radix);
        }

        ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

        DkmEvaluateReturnValueAsyncResult orig, other;
        Forwarder.Forward((wl, cr) => c.Same.EvaluateReturnValue(wl, stackFrame, rawReturnValue, cr),
            c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmEvaluateReturnValueAsyncResult>>)
                ((wl, cr) => c.Other.EvaluateReturnValue(wl, stackFrame, rawReturnValue, cr)), r => r.ErrorCode,
            DkmEvaluateReturnValueAsyncResult.CreateErrorResult, out orig, out other);

        if (orig.ErrorCode != 0 || orig.ResultObject == null)
        {
          DkmCleanup.Close(other.ResultObject);
          return orig;
        }

        return new DkmEvaluateReturnValueAsyncResult(ResultWrapper.Wrap(orig.ResultObject, other.ResultObject, inspectionContext));
      });
    }

    void IDkmLanguageReturnValueEvaluator2.EvaluateReturnValue2(DkmInspectionContext inspectionContext, DkmWorkList workList,
        DkmStackWalkFrame stackFrame, DkmRawReturnValueContainer rawReturnValue,
        DkmCompletionRoutine<DkmEvaluateReturnValueAsyncResult2> completionRoutine)
    {
      Answer(completionRoutine, DkmEvaluateReturnValueAsyncResult2.CreateErrorResult, () =>
      {
        DebugLog.Use(inspectionContext);

        if (DebugLog.Enabled)
        {
          DebugLog.Write("EvaluateReturnValue2 (Autos 'returned' row), radix " + inspectionContext.Radix);
        }

        ForwardingContexts c = ForwardingContexts.Create(inspectionContext, true);

        DkmEvaluateReturnValueAsyncResult2 orig, other;
        Forwarder.Forward((wl, cr) => c.Same.EvaluateReturnValue2(wl, stackFrame, rawReturnValue, cr),
            c.Other == null ? null : (Action<DkmWorkList, DkmCompletionRoutine<DkmEvaluateReturnValueAsyncResult2>>)
                ((wl, cr) => c.Other.EvaluateReturnValue2(wl, stackFrame, rawReturnValue, cr)), r => r.ErrorCode,
            DkmEvaluateReturnValueAsyncResult2.CreateErrorResult, out orig, out other);

        if (orig.ErrorCode != 0 || orig.ResultObject == null)
        {
          DkmCleanup.Close(other.ResultObject);
          return orig;
        }

        return new DkmEvaluateReturnValueAsyncResult2(ResultWrapper.Wrap(orig.ResultObject, other.ResultObject, inspectionContext));
      });
    }

    // =================================================================================

    /// <summary>
    /// Runs <paramref name="compute"/> and passes its answer to <paramref name="completionRoutine"/>,
    /// exactly once. An exception of our own (a request that cannot be appended, a request
    /// routed back to us, a bug) becomes an error answer for VS instead of leaving the
    /// interface method. The completion routine is called outside the try, so an exception
    /// from VS's routine is not answered a second time.
    /// </summary>
    internal static void Answer<T>(DkmCompletionRoutine<T> completionRoutine, Func<Exception, T> errorResult, Func<T> compute)
        where T : struct
    {
      T answer;

      try
      {
        answer = compute();
      }
      catch (Exception e)
      {
        answer = errorResult(e);
      }

      completionRoutine(answer);
    }
  }
}

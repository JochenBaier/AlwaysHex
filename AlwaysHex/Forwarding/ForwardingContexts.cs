// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
  /// <summary>
  /// The two inspection contexts used to ask the real EE:
  /// <see cref="Same"/> = the user's radix, <see cref="Other"/> = the other radix.
  /// Both carry our private vendor id, so VS routes them to the real EE, not to us
  /// (see "THE ROUTING TRICK" in AlwaysHexEvaluator.cs).
  /// <see cref="Other"/> is null when a second evaluation is not wanted (format
  /// specifier, unusual radix).
  /// </summary>
  internal sealed class ForwardingContexts
  {
    /// <summary>
    /// Private "compiler vendor" of our forwarded requests. Any GUID works as long as it is
    /// not Microsoft's vendor id.
    /// </summary>
    internal static readonly Guid ForwardVendorId = new Guid("6E1A9D42-35C8-4F0B-A7E3-2D94B8C1F5A0");

    /// <summary>
    /// Added to the evaluation flags of <see cref="Other"/>: the second evaluation must never
    /// change the program, so no side effects (e.g. "i++" in Watch) and no function calls.
    /// </summary>
    internal const DkmEvaluationFlags OtherFlags = DkmEvaluationFlags.NoSideEffects | DkmEvaluationFlags.NoFuncEval;

    public DkmInspectionContext Same;
    public DkmInspectionContext Other;

    /// <summary>
    /// Throws if <paramref name="context"/> is one of our forwarding contexts: VS routed a
    /// forwarded request back to us (our filter should prevent that). Forwarding it again
    /// would loop. Works on any thread, unlike a depth counter.
    /// </summary>
    public static void ThrowIfForwarded(DkmInspectionContext context)
    {
      if (context != null && context.Language != null && context.Language.Id.VendorId == ForwardVendorId)
      {
        throw new InvalidOperationException("AlwaysHex: forwarded request was routed back to AlwaysHex");
      }
    }

    /// <param name="context">The context VS gave us.</param>
    /// <param name="dual">False: only <see cref="Same"/> is created.</param>
    public static ForwardingContexts Create(DkmInspectionContext context, bool dual)
    {
      ThrowIfForwarded(context);

      // Same language (C or C++), but our private vendor id.
      DkmLanguage language = DkmLanguage.Create(context.Language.Name, new DkmCompilerId(ForwardVendorId, context.Language.Id.LanguageId));

      var c = new ForwardingContexts();
      c.Same = CreateContext(context, language, context.EvaluationFlags, context.Radix);

      if (dual && (context.Radix == 10 || context.Radix == 16))
      {
        try
        {
          c.Other = CreateContext(context, language, context.EvaluationFlags | OtherFlags, context.Radix == 16 ? 10u : 16u);
        }
        catch (Exception)
        {
          // No second context: the value is shown in the user's radix only.
        }
      }

      return c;
    }

    // A copy of the caller's context with a different language, flags and radix.
    private static DkmInspectionContext CreateContext(DkmInspectionContext context, DkmLanguage language, DkmEvaluationFlags flags,
        uint radix)
    {
      return DkmInspectionContext.Create(context.InspectionSession, context.RuntimeInstance, context.Thread, context.Timeout, flags,
          context.FuncEvalFlags, radix, language, context.ReturnValue, context.AdditionalVisualizationData,
          context.AdditionalVisualizationDataPriority, context.ReturnValues, context.SymbolsConnection);
    }
  }
}

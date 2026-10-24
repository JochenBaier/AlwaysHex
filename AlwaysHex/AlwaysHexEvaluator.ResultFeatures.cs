// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using Microsoft.VisualStudio.Debugger.ComponentInterfaces;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
  /// <summary>
  /// Debugger features that VS calls on a result shown in Watch/Locals (see AlwaysHexEvaluator.cs
  /// for the overview): "Break When Value Changes", pinned members ("favorites") and
  /// "Make Object ID". The result VS holds is one of ours, which lacks the EE's private data,
  /// so each request is passed on to the EE's original result; its private vendor id routes
  /// the call to the EE, not back to us. These methods are synchronous and report failure by
  /// exception (Concord turns it into an error code), so an exception of the EE is passed on
  /// as it is: VS sees the same failure it would see without AlwaysHex.
  /// </summary>
  public sealed partial class AlwaysHexEvaluator :
      IDkmDataBreakpointInfoProvider,
      IDkmDataBreakpointInfoProvider160,
      IDkmObjectFavoritesProvider,
      IDkmLanguageObjectIdProvider
  {
    // --- Break When Value Changes ---------------------------------------------------

    DkmDataBreakpointInfo IDkmDataBreakpointInfoProvider.GetDataBreakpointInfo(DkmSuccessEvaluationResult successResult, out string error)
    {
      DkmSuccessEvaluationResult inner = InnerSuccess(successResult);

      if (inner == null)
      {
        // Not created by us: calling it again would come straight back here.
        error = "AlwaysHex: unknown evaluation result";
        return default(DkmDataBreakpointInfo);
      }

      return inner.GetDataBreakpointInfo(out error);
    }

    string IDkmDataBreakpointInfoProvider160.GetDataBreakpointDisplayName(DkmSuccessEvaluationResult successResult)
    {
      DkmSuccessEvaluationResult inner = InnerSuccess(successResult);
      return inner != null ? inner.GetDataBreakpointDisplayName() : null;
    }

    // --- Pinned members ("favorites") ---------------------------------------------------

    void IDkmObjectFavoritesProvider.AddToFavorites(DkmSuccessEvaluationResult successResult, DkmSuccessEvaluationResult child)
    {
      RequireInner(successResult).AddToFavorites(RequireInner(child));
    }

    void IDkmObjectFavoritesProvider.RemoveFromFavorites(DkmSuccessEvaluationResult successResult, DkmSuccessEvaluationResult child)
    {
      RequireInner(successResult).RemoveFromFavorites(RequireInner(child));
    }

    // --- Make Object ID ---------------------------------------------------------------

    void IDkmLanguageObjectIdProvider.CreateObjectId(DkmEvaluationResult evaluationResult)
    {
      RequireInner(evaluationResult).CreateObjectId();
    }

    void IDkmLanguageObjectIdProvider.DestroyObjectId(DkmEvaluationResult evaluationResult)
    {
      RequireInner(evaluationResult).DestroyObjectId();
    }

    // --- helpers ------------------------------------------------------------------------

    /// <summary>The EE's original success result behind one of ours, or null.</summary>
    private static DkmSuccessEvaluationResult InnerSuccess(DkmEvaluationResult result)
    {
      WrappedResult wrapped = result.GetDataItem<WrappedResult>();
      return wrapped != null ? wrapped.Inner as DkmSuccessEvaluationResult : null;
    }

    /// <summary>
    /// The EE's original result behind one of ours. A result not created by us cannot be
    /// passed on (it would come straight back here), so the request fails instead.
    /// </summary>
    private static DkmSuccessEvaluationResult RequireInner(DkmEvaluationResult result)
    {
      DkmSuccessEvaluationResult inner = InnerSuccess(result);

      if (inner == null)
      {
        throw new NotSupportedException("AlwaysHex: unknown evaluation result");
      }

      return inner;
    }
  }
}

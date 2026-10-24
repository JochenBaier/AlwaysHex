// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
  /// <summary>
  /// Re-creates the real EE's answers for Visual Studio: with the caller's context (so that
  /// follow-up requests come back to us) and with the value in both radixes.
  /// </summary>
  internal static class ResultWrapper
  {
    /// <summary>
    /// Wrap for a whole list; <paramref name="other"/>[i] is the twin of <paramref name="orig"/>[i].
    /// Wrap only merges a pair when the names match and both numbers are the same value, so
    /// lists that do not line up just keep their original values.
    /// </summary>
    public static DkmEvaluationResult[] WrapAll(DkmEvaluationResult[] orig, DkmEvaluationResult[] other, DkmInspectionContext context)
    {
      var wrapped = new DkmEvaluationResult[orig.Length];

      for (int i = 0; i < orig.Length; i++)
      {
        DkmEvaluationResult o = other != null && i < other.Length ? other[i] : null;
        wrapped[i] = Wrap(orig[i], o, context);
      }

      // Twins without a counterpart (other list longer) are not used.
      if (other != null)
      {
        for (int i = orig.Length; i < other.Length; i++)
        {
          DkmCleanup.Close(other[i]);
        }
      }

      return wrapped;
    }

    /// <summary>
    /// Re-creates <paramref name="inner"/> (an answer of the real EE) for VS:
    /// <list type="bullet">
    /// <item>with the caller's <paramref name="context"/>, so follow-up requests come to us;</item>
    /// <item>with the value in both radixes, if <paramref name="other"/> (the same row in the
    /// other radix) pairs up;</item>
    /// <item>with a <see cref="WrappedResult"/> data item pointing at <paramref name="inner"/>.</item>
    /// </list>
    /// Everything else (name, type, editable value, flags, refresh button text, error
    /// category) is copied unchanged.
    /// </summary>
    public static DkmEvaluationResult Wrap(DkmEvaluationResult inner, DkmEvaluationResult other, DkmInspectionContext context)
    {
      try
      {
        var success = inner as DkmSuccessEvaluationResult;

        if (success != null)
        {
          var x = other as DkmSuccessEvaluationResult;
          string value = null;

          if (x != null && SameItem(success.Name, x.Name))
          {
            // Two renderings from the EE -> merge plain values first, then short
            // struct summaries.
            value = ValueMerger.MergeValue(success.Value, x.Value, context.Radix == 16) ??
                            ValueMerger.MergeSummary(success.Value, x.Value, context.Radix == 16);
          }

          if (DebugLog.Enabled)
          {
            DebugLog.Write("  Wrap " + success.Name + " [" + success.Type + "]: " + DebugLog.Show(success.Value) + " + " +
                            (x == null ? "(no other-radix answer)" : DebugLog.Show(x.Value)) + " -> " +
                            (value != null ? DebugLog.Show(value)
                                : x == null ? "one radix"
                                : !SameItem(success.Name, x.Name) ? "unchanged (the rows do not match)"
                                : "unchanged (no number, not the same number, or a long summary)"));
          }

          return DkmSuccessEvaluationResult.Create(context, success.StackFrame, success.Name, success.FullName, success.Flags,
              value ?? success.Value, success.EditableValue, success.Type, success.Category, success.Access, success.StorageType,
              success.TypeModifierFlags, success.Address, success.CustomUIVisualizers, success.ExternalModules, success.RefreshButtonText,
              new WrappedResult(inner));
        }

        // Errors ("identifier not found", ...) are wrapped too, so that every row VS
        // holds belongs to us and follow-up requests stay on our side.
        var failed = inner as DkmFailedEvaluationResult;

        if (failed != null)
        {
          if (DebugLog.Enabled)
          {
            DebugLog.Write("  Wrap " + DebugLog.Show(failed) + " (error row, passed on)");
          }

          return DkmFailedEvaluationResult.Create(context, failed.StackFrame, failed.Name, failed.FullName, failed.ErrorMessage,
              failed.Flags, failed.Type, failed.Category, new WrappedResult(inner));
        }

        // Other result kinds (intermediate, ...) are passed through untouched.
        return inner;
      }
      catch (Exception)
      {
        // Never lose a value because of our own bug: fall back to the EE's answer.
        return inner;
      }
      finally
      {
        // The other-radix twin was only needed for its value string.
        if (other != null)
        {
          try { other.Close(); } catch (Exception) { }
        }
      }
    }

    /// <summary>
    /// Re-creates an enum context ("the remaining rows") for VS, under the caller's context,
    /// with a <see cref="WrappedEnum"/> data item that holds the real EE's enum contexts
    /// for both radixes. GetItems uses them later.
    /// </summary>
    public static DkmEvaluationResultEnumContext WrapEnum(DkmEvaluationResultEnumContext inner, DkmEvaluationResultEnumContext other,
        DkmInspectionContext context)
    {
      if (inner == null)
      {
        DkmCleanup.Close(other);
        return null;
      }

      try
      {
        return DkmEvaluationResultEnumContext.Create(inner.Count, inner.StackFrame, context, new WrappedEnum(inner, other));
      }
      catch (Exception)
      {
        // No enum context of ours holds them, so nobody else would close them before the
        // inspection session ends. The caller turns the exception into an error answer.
        DkmCleanup.Close(inner);
        DkmCleanup.Close(other);
        throw;
      }
    }

    /// <summary>The real EE's result behind one of ours; other results are returned as they are.</summary>
    public static DkmEvaluationResult Unwrap(DkmEvaluationResult result)
    {
      WrappedResult wrapped = result.GetDataItem<WrappedResult>();
      return wrapped != null ? wrapped.Inner : result;
    }

    // Array elements are named by index in the current radix ("[10]" vs "[0x0000000a]").
    private static bool SameItem(string name, string otherName)
    {
      if (name == otherName)
      {
        return true;
      }

      return name != null && otherName != null && name.StartsWith("[", StringComparison.Ordinal) &&
                otherName.StartsWith("[", StringComparison.Ordinal);
    }
  }
}

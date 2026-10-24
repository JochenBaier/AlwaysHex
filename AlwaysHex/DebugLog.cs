// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Jochen Baier

using System;
using Microsoft.VisualStudio.Debugger;
using Microsoft.VisualStudio.Debugger.Evaluation;

namespace AlwaysHex
{
  /// <summary>
  /// Optional trace of the C/C++ component in Visual Studio's Output window (Debug pane), to see
  /// what happens when you hover over a variable: which requests arrive, what the C++ expression
  /// evaluator answers in both radixes, and what is merged. Off unless Visual Studio was started
  /// with the environment variable ALWAYSHEX_TRACE=1; then every line starts with "AlwaysHex:".
  /// Callers check <see cref="Enabled"/> first, so no text is built when tracing is off.
  /// </summary>
  internal static class DebugLog
  {
    internal static readonly bool Enabled = Environment.GetEnvironmentVariable("ALWAYSHEX_TRACE") == "1";

    // The debugged process of the request running on this thread: its connection carries the
    // message to the Output window. Set by each entry point (Use).
    [ThreadStatic]
    private static DkmProcess s_process;

    /// <summary>Remembers the process of the request that starts on this thread.</summary>
    internal static void Use(DkmInspectionContext context)
    {
      if (!Enabled)
      {
        return;
      }

      try
      {
        s_process = context != null && context.RuntimeInstance != null ? context.RuntimeInstance.Process : null;
      }
      catch (Exception)
      {
        s_process = null;
      }
    }

    /// <summary>One line in the Output window. Never throws.</summary>
    internal static void Write(string text)
    {
      DkmProcess process = s_process;

      if (!Enabled || process == null)
      {
        return;
      }

      try
      {
        DkmUserMessage.Create(process.Connection, process, DkmUserMessageOutputKind.UnfilteredOutputWindowMessage,
            "AlwaysHex: " + text + Environment.NewLine, MessageBoxFlags.None, 0).Post();
      }
      catch (Exception)
      {
      }
    }

    /// <summary>A value for the log: quoted, shortened to 120 characters, null as "(none)".</summary>
    internal static string Show(string value)
    {
      if (value == null)
      {
        return "(none)";
      }

      return "'" + (value.Length > 120 ? value.Substring(0, 117) + "..." : value) + "'";
    }

    /// <summary>A result for the log: its name and value, or the error message of a failed one.</summary>
    internal static string Show(DkmEvaluationResult result)
    {
      if (result == null)
      {
        return "(none)";
      }

      try
      {
        var success = result as DkmSuccessEvaluationResult;

        if (success != null)
        {
          return success.Name + " = " + Show(success.Value) + " [" + success.Type + "]";
        }

        var failed = result as DkmFailedEvaluationResult;

        if (failed != null)
        {
          return failed.Name + ": error " + Show(failed.ErrorMessage);
        }

        return result.Name + " (" + result.TagValue + ")";
      }
      catch (Exception)
      {
        return "(unreadable)";
      }
    }
  }
}

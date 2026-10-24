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
    // Backstops against endless recursion. The real check is the vendor id
    // (ForwardingContexts.ThrowIfForwarded): a request that carries our private vendor id
    // was routed back to us, on whatever thread. It cannot see a loop in which someone
    // re-creates the context with Microsoft's vendor id on the way, so two limits stop that:
    //
    // MaxDepth (per thread): nesting itself is legal, e.g. a component below the EE (a
    // custom visualizer) may evaluate C++ with Microsoft's vendor id while our request runs;
    // that reaches us once more and is forwarded normally. Only a loop gets this deep (the
    // measured depth is 1).
    //
    // MaxInFlight (whole process): a loop whose next level runs on another thread while
    // this one waits in Execute() starts at depth 0 on every thread, so the depth never
    // grows. Each such level keeps one forward in flight; the cap ends the chain with an
    // error. Visual Studio sends native evaluation requests one at a time: the peak was 1
    // in flight (depth 1) in VS 2022 17.14 and VS 2026 18.11 during the stress tests and
    // with 259 threads, Threads, Parallel Stacks, Call Stack, Locals, Autos and Watch open
    // while switching threads, toggling hex and stepping (measured 2026-10-22).
    //
    // Failure latch: the two limits alone bound how many forwards run at once, not how many
    // run in total. In a loop every level has queued two requests; when one branch fails at
    // a limit and completes, its slot is free again and the sibling still waiting in the
    // same Execute() recurses anew, so the work can grow exponentially. Therefore the first
    // failed limit sets s_tripped, and while it is set every new forward fails at once: the
    // queued siblings cost one cheap failed request each and nothing expands further. The
    // latch belongs to the forwards active at that moment (the "cohort"): it is cleared when
    // the last of them has finished (s_inFlight back to 0), so AlwaysHex works normally
    // again after the loop has unwound. It also expires LatchMs after it tripped: otherwise
    // one forward of that cohort that never finishes (an EE that hangs) would refuse every
    // C/C++ evaluation for the rest of the session. If the loop still runs after the expiry,
    // the limits trip the latch again right away, so an expiry lets through only one short
    // wave of requests, not the exponential growth. A request that arrives while the latch is
    // set, even an unrelated one, gets an error answer; with the measured peak of 1 in flight
    // that happens only during such a loop. Counter and latch change together under s_gate, so a forward that
    // starts while the last one leaves sees either the old cohort or the new state, never a
    // mix. Nothing here relies on a marker that another component would have to keep.
    private const int MaxDepth = 4;
    private const int MaxInFlight = 64;
    private const int LatchMs = 5000;

    [ThreadStatic]
    private static int s_depth;

    private static readonly object s_gate = new object();
    private static int s_inFlight;      // under s_gate
    private static bool s_tripped;      // under s_gate
    private static int s_trippedAt;     // under s_gate: Environment.TickCount when it tripped

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
    public static void Forward<T>(Action<DkmWorkList, DkmCompletionRoutine<T>> call, Action<DkmWorkList, DkmCompletionRoutine<T>> callOther,
        Func<T, int> errorCode, Func<Exception, T> errorResult, out T first, out T second)
        where T : struct
    {
      T a = default(T);
      T b = default(T);
      bool gotFirst = false;
      DkmWorkList own = null;

      // Nothing has started yet when Enter refuses, so there is nothing to clean up; the
      // caller turns the exception into an error answer.
      string refused = Enter();

      if (refused != null)
      {
        if (DebugLog.Enabled)
        {
          DebugLog.Write("  forwarding refused: " + refused);
        }

        throw new InvalidOperationException(refused);
      }

      s_depth++;
      var watch = DebugLog.Enabled ? System.Diagnostics.Stopwatch.StartNew() : null;

      try
      {
        own = DkmWorkList.Create(null);
        call(own, r => { a = r; gotFirst = true; });

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

        if (DebugLog.Enabled)
        {
          DebugLog.Write("  forwarded " + (callOther != null ? "2 requests (your radix and the other one)" : "1 request") +
                        " to the C++ EE under the private vendor id: " + watch.ElapsedMilliseconds + " ms (depth " + s_depth + ")");
        }
      }
      catch (OperationCanceledException e)
      {
        if (DebugLog.Enabled)
        {
          DebugLog.Write("  canceled by Visual Studio after " + watch.ElapsedMilliseconds + " ms" +
                        (gotFirst ? ": first answer already there, kept" : ": answered with a 'canceled' error"));
        }

        // VS canceled the request while we were waiting (e.g. the user toggled
        // Hexadecimal Display while the Call Stack window was being filled). VS no
        // longer wants the answer: reply with a "canceled" error instead of letting
        // the exception leave AlwaysHex. (If VS cancels a little later, Execute()
        // returns normally and the answers themselves are "canceled" errors.)
        // Execute() fires all completion routines before it returns, also when it is
        // canceled, so the first answer may have arrived already. Then it is kept: its
        // objects belong to whoever receives it, and replacing it would leave them
        // unclosed until the inspection session ends. The caller handles it as usual
        // (closes the twin, or wraps it and hands it to VS like the EE would).
        Cancel(own);

        if (!gotFirst)
        {
          a = errorResult(e);
        }
      }
      catch (Exception e)
      {
        // Append or Execute failed. The caller turns the exception into an error answer.
        if (DebugLog.Enabled)
        {
          DebugLog.Write("  forwarding failed: " + e.Message);
        }

        Cancel(own);
        throw;
      }
      finally
      {
        s_depth--;
        Leave();
      }

      first = a;
      // Without the second answer the value is simply shown in the user's radix only.
      second = errorCode(b) == 0 ? b : default(T);
    }

    // Starts a forward, or returns why it may not start (see "Failure latch" above). A failed
    // limit always trips the latch with at least one forward still active (this thread's,
    // for MaxDepth), so the latch is cleared by a later Leave(), or here after LatchMs.
    private static string Enter()
    {
      lock (s_gate)
      {
        // TickCount wraps around after 24.9 days; the difference of two values is still
        // right in unchecked int arithmetic.
        if (s_tripped && unchecked(Environment.TickCount - s_trippedAt) >= LatchMs)
        {
          s_tripped = false;
        }

        if (s_tripped)
        {
          return "AlwaysHex: forwarding paused until a runaway chain of requests has ended";
        }

        if (s_depth >= MaxDepth)
        {
          return Trip("AlwaysHex: forwarded requests nest too deep");
        }

        if (s_inFlight >= MaxInFlight)
        {
          return Trip("AlwaysHex: too many forwarded requests at once");
        }

        s_inFlight++;
        return null;
      }
    }

    // Sets the latch (caller holds s_gate) and returns the reason.
    private static string Trip(string reason)
    {
      s_tripped = true;
      s_trippedAt = Environment.TickCount;
      return reason;
    }

    // Ends a forward that Enter started; the last one of a cohort clears the latch.
    private static void Leave()
    {
      lock (s_gate)
      {
        if (--s_inFlight == 0)
        {
          s_tripped = false;
        }
      }
    }

    // A work list lives until it has run or was canceled; "callers should ensure that
    // 'Cancel' is called in the case of failure" (DkmWorkList.Create). After a canceled
    // Execute() this is a no-op; it matters when appending or Execute() failed otherwise.
    // Cancel(false) does not wait and is ignored when the list is already complete or canceled.
    private static void Cancel(DkmWorkList own)
    {
      if (own == null)
      {
        return;
      }

      try { own.Cancel(false); } catch (Exception) { }
    }
  }
}

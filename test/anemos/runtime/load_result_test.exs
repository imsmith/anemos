defmodule Anemos.Runtime.LoadResultTest do
  @moduledoc """
  Regression tests for `Anemos.Runtime.load/2` swallowing failures.

  `load/2` called `Dispatcher.load/2` and `Scheduler.schedule/2` in bare
  statements and returned a hardcoded `:ok`. A policy whose every schedule
  was rejected, or whose data blocks named a protocol nobody handles, got
  `:ok` back — so the author never learned the policy was inert.
  """
  use ExUnit.Case, async: false

  # --- Everything armed ---

  test "a fully loadable policy still returns :ok" do
    start_supervised!({Anemos.Runtime, name: :load_ok})

    assert :ok =
             Anemos.Runtime.load(:load_ok, """
             rule lights-on {
               when MOTION {
                 log "motion"
               }
             }
             """)
  end

  test "a policy with an armable schedule returns :ok" do
    start_supervised!({Anemos.Runtime, name: :load_ok_sched})

    assert :ok =
             Anemos.Runtime.load(:load_ok_sched, """
             rule ticker {
               at interval(5min) {
                 log "tick"
               }
             }
             """)
  end

  # --- Schedule failures reach the caller ---

  test "a past-dated schedule is reported, not swallowed" do
    start_supervised!({Anemos.Runtime, name: :load_past_date})

    assert {:partial, failures} =
             Anemos.Runtime.load(:load_past_date, """
             rule stale {
               at DATE_1999.01.01 {
                 log "never"
               }
             }
             """)

    assert [%{code: "anemos.scheduler/date_in_past", field: event}] = failures
    assert event =~ "1999"
  end

  test "a partial failure still loads the rules that were fine" do
    start_supervised!({Anemos.Runtime, name: :load_partial})

    assert {:partial, failures} =
             Anemos.Runtime.load(:load_partial, """
             rule stale {
               at DATE_1999.01.01 {
                 log "never"
               }
             }

             rule live {
               when MOTION {
                 log "motion"
               }
             }
             """)

    assert [%{code: "anemos.scheduler/" <> _}] = failures

    # Partial must not mean nothing loaded.
    assert {:ok, [%{type: :log, value: "motion"}]} =
             Anemos.Runtime.dispatch(:load_partial, "MOTION")
  end

  # --- Dispatcher-side failures reach the caller (ISSUES.md A-22) ---

  test "a data block naming an unhandled protocol is reported, not swallowed" do
    start_supervised!({Anemos.Runtime, name: :load_bad_proto})

    assert {:partial, failures} =
             Anemos.Runtime.load(:load_bad_proto, """
             data missing-handler {
               dynamic {
                 subscribe unknown-proto "test://nowhere"
               }
             }

             rule r {
               when EV {
                 log "ok"
               }
             }
             """)

    assert [%{code: "anemos.data/no_subscribable_handler", field: "missing-handler"}] =
             failures

    # The rule alongside it still loaded.
    assert {:ok, [%{type: :log, value: "ok"}]} = Anemos.Runtime.dispatch(:load_bad_proto, "EV")
  end

  test "schedule and data block failures are reported together" do
    start_supervised!({Anemos.Runtime, name: :load_both})

    assert {:partial, failures} =
             Anemos.Runtime.load(:load_both, """
             data missing-handler {
               dynamic {
                 subscribe unknown-proto "test://nowhere"
               }
             }

             rule stale {
               at DATE_1999.01.01 {
                 log "never"
               }
             }
             """)

    assert Enum.any?(
             failures,
             &match?(%{code: "anemos.data/" <> _, field: "missing-handler"}, &1)
           )

    assert Enum.any?(failures, &match?(%{code: "anemos.scheduler/" <> _}, &1))
  end

  # --- Total failure is still distinguishable from partial ---

  test "a parse error is still {:error, _}, not {:partial, _}" do
    start_supervised!({Anemos.Runtime, name: :load_parse_err})
    assert {:error, _} = Anemos.Runtime.load(:load_parse_err, "rule {")
  end
end

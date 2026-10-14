defmodule Anemos.Runtime.SchedulerTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.Runtime.Scheduler

  test "starts with no schedules" do
    {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_empty)
    assert Process.alive?(pid)
  end

  test "interval schedule fires repeatedly" do
    test_pid = self()

    {:ok, pid} =
      Scheduler.start_link(
        runtime_name: :test_sched_interval,
        min_interval_ms: 10,
        dispatch_fn: fn event_name, _context ->
          send(test_pid, {:dispatched, event_name})
        end
      )

    assert :ok =
             Scheduler.schedule(pid, [
               %Anemos.CompiledSchedule{
                 event_name: "AT_INTERVAL_test",
                 time_spec: {:interval, {50, :ms}},
                 recurrence: :interval
               }
             ])

    assert_receive {:dispatched, "AT_INTERVAL_test"}, 200
    assert_receive {:dispatched, "AT_INTERVAL_test"}, 200
  end

  test "one-shot delay fires once" do
    test_pid = self()

    {:ok, pid} =
      Scheduler.start_link(
        runtime_name: :test_sched_oneshot,
        dispatch_fn: fn event_name, _context ->
          send(test_pid, {:dispatched, event_name})
        end
      )

    Scheduler.schedule(pid, [
      %Anemos.CompiledSchedule{
        event_name: "AT_TEST_ONESHOT",
        time_spec: {:delay_ms, 50},
        recurrence: nil
      }
    ])

    assert_receive {:dispatched, "AT_TEST_ONESHOT"}, 200
    refute_receive {:dispatched, "AT_TEST_ONESHOT"}, 100
  end

  test "multiple schedules can be loaded" do
    test_pid = self()

    {:ok, pid} =
      Scheduler.start_link(
        runtime_name: :test_sched_multi,
        dispatch_fn: fn event_name, _context ->
          send(test_pid, {:dispatched, event_name})
        end
      )

    Scheduler.schedule(pid, [
      %Anemos.CompiledSchedule{
        event_name: "AT_A",
        time_spec: {:delay_ms, 30},
        recurrence: nil
      },
      %Anemos.CompiledSchedule{
        event_name: "AT_B",
        time_spec: {:delay_ms, 60},
        recurrence: nil
      }
    ])

    assert_receive {:dispatched, "AT_A"}, 200
    assert_receive {:dispatched, "AT_B"}, 200
  end

  # --- Interval floor ---

  describe "interval floor" do
    test "an interval below the floor is rejected, not armed" do
      test_pid = self()

      {:ok, pid} = start_sched(:test_sched_floor, test_pid)

      assert {:error, failures} =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_INTERVAL_flood",
                   time_spec: {:interval, {1, :ms}},
                   recurrence: :interval
                 }
               ])

      assert [%{code: "anemos.scheduler/interval_below_minimum", field: "AT_INTERVAL_flood"}] =
               failures

      refute_receive {:dispatched, "AT_INTERVAL_flood"}, 100
    end

    test "the floor defaults to one second" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_floor_default)

      assert {:error, [%{code: "anemos.scheduler/interval_below_minimum"}]} =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_INTERVAL_999",
                   time_spec: {:interval, {999, :ms}},
                   recurrence: :interval
                 }
               ])
    end

    test "an interval at or above the floor is armed" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_floor_ok)

      assert :ok =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_INTERVAL_slow",
                   time_spec: {:interval, {1, :s}},
                   recurrence: :interval
                 }
               ])
    end

    test "a rejected schedule does not block the rest of the batch" do
      test_pid = self()
      {:ok, pid} = start_sched(:test_sched_partial, test_pid)

      assert {:error, [%{field: "AT_TOO_FAST"}]} =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_TOO_FAST",
                   time_spec: {:interval, {1, :ms}},
                   recurrence: :interval
                 },
                 %Anemos.CompiledSchedule{
                   event_name: "AT_FINE",
                   time_spec: {:delay_ms, 30},
                   recurrence: nil
                 }
               ])

      assert_receive {:dispatched, "AT_FINE"}, 200
    end
  end

  # --- Schedule count cap ---

  describe "schedule cap" do
    test "schedules beyond the cap are rejected" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_cap, max_schedules: 2)

      specs =
        for n <- 1..4 do
          %Anemos.CompiledSchedule{
            event_name: "AT_CAP_#{n}",
            time_spec: {:delay_ms, 60_000},
            recurrence: nil
          }
        end

      assert {:error, failures} = Scheduler.schedule(pid, specs)

      assert [
               %{code: "anemos.scheduler/schedule_limit_exceeded", field: "AT_CAP_3"},
               %{code: "anemos.scheduler/schedule_limit_exceeded", field: "AT_CAP_4"}
             ] = failures
    end

    test "the cap is enforced across separate schedule calls" do
      {:ok, pid} =
        Scheduler.start_link(runtime_name: :test_sched_cap_cumulative, max_schedules: 1)

      spec = fn name ->
        %Anemos.CompiledSchedule{
          event_name: name,
          time_spec: {:delay_ms, 60_000},
          recurrence: nil
        }
      end

      assert :ok = Scheduler.schedule(pid, [spec.("AT_FIRST")])

      assert {:error, [%{code: "anemos.scheduler/schedule_limit_exceeded", field: "AT_SECOND"}]} =
               Scheduler.schedule(pid, [spec.("AT_SECOND")])
    end
  end

  # --- Schedules that can never fire ---

  describe "unarmable schedules" do
    test "a past-dated schedule reports failure instead of :ok" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_past)

      assert {:error, [%{code: "anemos.scheduler/date_in_past", field: "AT_DATE_past"}]} =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_DATE_past",
                   time_spec: {:date, {1999, 1, 1}},
                   recurrence: nil
                 }
               ])
    end

    test "an unresolvable NLD schedule reports failure instead of :ok" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_nld_bad)

      assert {:error, [%{code: "anemos.scheduler/unresolvable_nld", field: "AT_NLD_gibberish"}]} =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_NLD_gibberish",
                   time_spec: {:nld, "gibberish"},
                   recurrence: nil
                 }
               ])
    end

    test "a past-dated NLD schedule reports failure instead of :ok" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_nld_past)

      assert {:error, [%{code: "anemos.scheduler/nld_in_past", field: "AT_NLD_yesterday"}]} =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_NLD_yesterday",
                   time_spec: {:nld, "yesterday"},
                   recurrence: nil
                 }
               ])
    end

    test "a schedule that cannot be armed leaves no phantom timer" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_phantom)

      assert {:error, _} =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_NLD_nope",
                   time_spec: {:nld, "nope"},
                   recurrence: nil
                 }
               ])

      refute Map.has_key?(:sys.get_state(pid).timers, "AT_NLD_nope")
    end
  end

  # --- Malformed durations ---

  test "an unrecognised duration unit does not take the scheduler down" do
    {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_bad_unit)

    assert {:error, [%{code: "anemos.scheduler/unknown_duration_unit", field: "AT_INTERVAL_bad"}]} =
             Scheduler.schedule(pid, [
               %Anemos.CompiledSchedule{
                 event_name: "AT_INTERVAL_bad",
                 time_spec: {:interval, {2, :fortnights}},
                 recurrence: :interval
               }
             ])

    assert Process.alive?(pid)
  end

  # --- A-19: same-name schedules collide and leak timers ---

  describe "colliding event names" do
    test "re-arming an event name cancels the displaced timer instead of leaking it" do
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          runtime_name: :test_sched_collide,
          dispatch_fn: fn event_name, _ctx -> send(test_pid, {:dispatched, event_name}) end
        )

      # Two `at 08:00` blocks in two unrelated rules compile to the same
      # synthetic event name. Both arm a timer; the map holds one.
      spec = %Anemos.CompiledSchedule{
        event_name: "AT_08_00",
        time_spec: {:delay_ms, 50},
        recurrence: nil
      }

      assert :ok = Scheduler.schedule(pid, [spec, spec])

      # One event name, one timer, one dispatch. The displaced timer must
      # not survive to produce a second, unattributable dispatch.
      assert_receive {:dispatched, "AT_08_00"}, 500
      refute_receive {:dispatched, "AT_08_00"}, 200

      assert map_size(:sys.get_state(pid).timers) == 1
    end

    test "a collision across separate schedule calls does not leak either" do
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          runtime_name: :test_sched_collide_calls,
          dispatch_fn: fn event_name, _ctx -> send(test_pid, {:dispatched, event_name}) end
        )

      spec = %Anemos.CompiledSchedule{
        event_name: "AT_08_00",
        time_spec: {:delay_ms, 60},
        recurrence: nil
      }

      assert :ok = Scheduler.schedule(pid, [spec])
      assert :ok = Scheduler.schedule(pid, [spec])

      assert_receive {:dispatched, "AT_08_00"}, 500
      refute_receive {:dispatched, "AT_08_00"}, 200
    end

    test "re-arming does not consume cap headroom" do
      {:ok, pid} =
        Scheduler.start_link(runtime_name: :test_sched_collide_cap, max_schedules: 1)

      spec = %Anemos.CompiledSchedule{
        event_name: "AT_08_00",
        time_spec: {:delay_ms, 60_000},
        recurrence: nil
      }

      assert :ok = Scheduler.schedule(pid, [spec])
      assert :ok = Scheduler.schedule(pid, [spec])
    end

    test "duplicate specs do not accumulate in the schedule list" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_collide_list)

      spec = %Anemos.CompiledSchedule{
        event_name: "AT_08_00",
        time_spec: {:delay_ms, 60_000},
        recurrence: nil
      }

      assert :ok = Scheduler.schedule(pid, [spec])
      assert :ok = Scheduler.schedule(pid, [spec])

      assert length(Scheduler.schedules(pid)) == 1
    end
  end

  # --- A-19: no unschedule path ---

  describe "unschedule" do
    test "unschedule/2 cancels the timer and forgets the spec" do
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          runtime_name: :test_sched_unschedule,
          dispatch_fn: fn event_name, _ctx -> send(test_pid, {:dispatched, event_name}) end
        )

      assert :ok =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_GONE",
                   time_spec: {:delay_ms, 60},
                   recurrence: nil
                 }
               ])

      assert :ok = Scheduler.unschedule(pid, ["AT_GONE"])

      refute_receive {:dispatched, "AT_GONE"}, 300
      assert Scheduler.schedules(pid) == []
    end

    test "unschedule/2 cancels an interval timer" do
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          runtime_name: :test_sched_unschedule_interval,
          min_interval_ms: 10,
          dispatch_fn: fn event_name, _ctx -> send(test_pid, {:dispatched, event_name}) end
        )

      assert :ok =
               Scheduler.schedule(pid, [
                 %Anemos.CompiledSchedule{
                   event_name: "AT_INTERVAL_gone",
                   time_spec: {:interval, {30, :ms}},
                   recurrence: :interval
                 }
               ])

      assert_receive {:dispatched, "AT_INTERVAL_gone"}, 300
      assert :ok = Scheduler.unschedule(pid, ["AT_INTERVAL_gone"])

      # Drain anything already in flight, then confirm it has stopped.
      receive do
        {:dispatched, "AT_INTERVAL_gone"} -> :ok
      after
        60 -> :ok
      end

      refute_receive {:dispatched, "AT_INTERVAL_gone"}, 200
    end

    test "unschedule/2 on an unknown event name is a no-op" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_unschedule_missing)
      assert :ok = Scheduler.unschedule(pid, ["AT_NEVER_ARMED"])
    end

    test "a recurring schedule does not resurrect itself after unschedule" do
      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          runtime_name: :test_sched_recurring_unschedule,
          dispatch_fn: fn event_name, _ctx -> send(test_pid, {:dispatched, event_name}) end
        )

      # A :fire_recurring already in the mailbox must not re-arm a timer for
      # an event the caller has just unscheduled.
      send(
        pid,
        {:fire_recurring, "AT_ZOMBIE",
         %Anemos.CompiledSchedule{
           event_name: "AT_ZOMBIE",
           time_spec: {:time, {0, 0}},
           recurrence: :day
         }}
      )

      assert_receive {:dispatched, "AT_ZOMBIE"}, 300
      assert :sys.get_state(pid).timers == %{}
    end
  end

  defp start_sched(name, test_pid) do
    Scheduler.start_link(
      runtime_name: name,
      min_interval_ms: 1_000,
      dispatch_fn: fn event_name, _context ->
        send(test_pid, {:dispatched, event_name})
      end
    )
  end
end

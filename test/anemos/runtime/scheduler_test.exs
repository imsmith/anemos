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

    {:ok, pid} = Scheduler.start_link(
      runtime_name: :test_sched_interval,
      min_interval_ms: 10,
      dispatch_fn: fn event_name, _context ->
        send(test_pid, {:dispatched, event_name})
      end
    )

    assert :ok = Scheduler.schedule(pid, [
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

    {:ok, pid} = Scheduler.start_link(
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

    {:ok, pid} = Scheduler.start_link(
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

      assert [{"AT_INTERVAL_flood", {:interval_below_minimum, 1, 1_000}}] = failures
      refute_receive {:dispatched, "AT_INTERVAL_flood"}, 100
    end

    test "the floor defaults to one second" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_floor_default)

      assert {:error, [{_, {:interval_below_minimum, 999, 1_000}}]} =
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

      assert {:error, [{"AT_TOO_FAST", _}]} =
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
               {"AT_CAP_3", {:schedule_limit_exceeded, 2}},
               {"AT_CAP_4", {:schedule_limit_exceeded, 2}}
             ] = failures
    end

    test "the cap is enforced across separate schedule calls" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_cap_cumulative, max_schedules: 1)

      spec = fn name ->
        %Anemos.CompiledSchedule{
          event_name: name,
          time_spec: {:delay_ms, 60_000},
          recurrence: nil
        }
      end

      assert :ok = Scheduler.schedule(pid, [spec.("AT_FIRST")])

      assert {:error, [{"AT_SECOND", {:schedule_limit_exceeded, 1}}]} =
               Scheduler.schedule(pid, [spec.("AT_SECOND")])
    end
  end

  # --- Schedules that can never fire ---

  describe "unarmable schedules" do
    test "a past-dated schedule reports failure instead of :ok" do
      {:ok, pid} = Scheduler.start_link(runtime_name: :test_sched_past)

      assert {:error, [{"AT_DATE_past", {:date_in_past, {1999, 1, 1}}}]} =
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

      assert {:error, [{"AT_NLD_gibberish", {:unresolvable_nld, "gibberish"}}]} =
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

      assert {:error, [{"AT_NLD_yesterday", {:nld_in_past, "yesterday"}}]} =
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

    assert {:error, [{"AT_INTERVAL_bad", {:unknown_duration_unit, :fortnights}}]} =
             Scheduler.schedule(pid, [
               %Anemos.CompiledSchedule{
                 event_name: "AT_INTERVAL_bad",
                 time_spec: {:interval, {2, :fortnights}},
                 recurrence: :interval
               }
             ])

    assert Process.alive?(pid)
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

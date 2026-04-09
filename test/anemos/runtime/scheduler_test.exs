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
      dispatch_fn: fn event_name, _context ->
        send(test_pid, {:dispatched, event_name})
      end
    )

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
end

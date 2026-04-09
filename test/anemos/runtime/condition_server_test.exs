defmodule Anemos.Runtime.ConditionServerTest do
  use ExUnit.Case, async: true
  @moduledoc false

  alias Anemos.Runtime.ConditionServer

  test "starts with state false" do
    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: []
    )
    assert ConditionServer.get_state(pid) == false
  end

  test "transitions to true when matching event arrives and evaluator returns true" do
    test_pid = self()
    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: [],
      on_transition: fn name -> send(test_pid, {:condition_true, name}) end
    )
    ConditionServer.handle_event(pid, "INFRA_ip4_addr_changed", %{})
    assert ConditionServer.get_state(pid) == true
    assert_receive {:condition_true, "networkchanged"}
  end

  test "does not broadcast when already true (true->true)" do
    test_pid = self()
    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: [],
      on_transition: fn name -> send(test_pid, {:condition_true, name}) end
    )
    ConditionServer.handle_event(pid, "INFRA_ip4_addr_changed", %{})
    assert_receive {:condition_true, "networkchanged"}
    ConditionServer.handle_event(pid, "INFRA_ip4_addr_changed", %{})
    refute_receive {:condition_true, "networkchanged"}, 50
  end

  test "transitions silently to false when evaluator returns false" do
    test_pid = self()
    call_count = :counters.new(1, [:atomics])
    {:ok, pid} = ConditionServer.start_link(
      name_str: "temp_high",
      subscriptions: ["TEMP_READING"],
      evaluator: fn _event, _ctx ->
        :counters.add(call_count, 1, 1)
        :counters.get(call_count, 1) == 1
      end,
      side_effects: [],
      on_transition: fn name -> send(test_pid, {:condition_true, name}) end
    )
    ConditionServer.handle_event(pid, "TEMP_READING", %{})
    assert ConditionServer.get_state(pid) == true
    assert_receive {:condition_true, "temp_high"}
    ConditionServer.handle_event(pid, "TEMP_READING", %{})
    assert ConditionServer.get_state(pid) == false
    refute_receive {:condition_true, "temp_high"}, 50
  end

  test "ignores non-subscribed events" do
    {:ok, pid} = ConditionServer.start_link(
      name_str: "networkchanged",
      subscriptions: ["INFRA_ip4_addr_changed"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: []
    )
    ConditionServer.handle_event(pid, "UNRELATED_EVENT", %{})
    assert ConditionServer.get_state(pid) == false
  end

  test "queryable at any time" do
    {:ok, pid} = ConditionServer.start_link(
      name_str: "test_cond",
      subscriptions: ["EV"],
      evaluator: fn _event, _ctx -> true end,
      side_effects: []
    )
    assert ConditionServer.get_state(pid) == false
    ConditionServer.handle_event(pid, "EV", %{})
    assert ConditionServer.get_state(pid) == true
  end
end

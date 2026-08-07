defmodule Anemos.Runtime.SupervisionTest do
  @moduledoc """
  Regression tests for the two-tier supervision rework.

  These cover the "silent policy loss" defect: any child of the dispatcher
  dying used to take the dispatcher with it, and the restarted dispatcher
  came back with an empty rule set — indistinguishable from "no rule matched".
  """
  use ExUnit.Case, async: false

  alias Anemos.Runtime.StoreSupervisor

  @policy """
  rule lights-on {
    when MOTION {
      log "motion"
    }
  }
  """

  defp start_runtime(name) do
    start_supervised!({Anemos.Runtime, name: name})
    :ok = Anemos.Runtime.load(name, @policy)
    assert {:ok, [%{type: :log}]} = Anemos.Runtime.dispatch(name, "MOTION")
    :ok
  end

  defp await_restart(name_atom, old_pid) do
    await_restart(name_atom, old_pid, 200)
  end

  defp await_restart(_name_atom, _old_pid, 0), do: flunk("process never restarted")

  defp await_restart(name_atom, old_pid, tries) do
    case Process.whereis(name_atom) do
      nil ->
        Process.sleep(10)
        await_restart(name_atom, old_pid, tries - 1)

      ^old_pid ->
        Process.sleep(10)
        await_restart(name_atom, old_pid, tries - 1)

      pid ->
        pid
    end
  end

  # --- Task 1: children are supervised, not linked to the dispatcher ---

  test "dispatcher does not start_link any stores" do
    start_runtime(:sup_t1)

    dispatcher = Process.whereis(:"sup_t1.dispatcher")
    {:links, links} = Process.info(dispatcher, :links)

    # The only link a dispatcher may hold is its own supervisor.
    sup = Process.whereis(:"sup_t1.supervisor")
    assert links == [sup], "dispatcher owns process links it should not: #{inspect(links)}"
  end

  test "store supervisor is part of the runtime tree" do
    start_runtime(:sup_t1b)
    sup = Process.whereis(:"sup_t1b.store_supervisor")
    assert is_pid(sup)

    assert is_pid(StoreSupervisor.whereis(sup, :triple_store))
    assert is_pid(StoreSupervisor.whereis(sup, :data_store))
    assert is_pid(StoreSupervisor.whereis(sup, :subscribable_registry))
  end

  test "killing the triple store does not kill the dispatcher and the policy still fires" do
    start_runtime(:sup_t1c)

    dispatcher = Process.whereis(:"sup_t1c.dispatcher")
    store_sup = Process.whereis(:"sup_t1c.store_supervisor")
    triple_store = StoreSupervisor.whereis(store_sup, :triple_store)

    Process.exit(triple_store, :kill)
    Process.sleep(50)

    assert Process.whereis(:"sup_t1c.dispatcher") == dispatcher,
           "dispatcher died when the triple store died"

    assert is_pid(StoreSupervisor.whereis(store_sup, :triple_store))
    assert {:ok, [%{type: :log}]} = Anemos.Runtime.dispatch(:sup_t1c, "MOTION")
  end

  test "killing the data store does not kill the dispatcher" do
    start_runtime(:sup_t1d)
    dispatcher = Process.whereis(:"sup_t1d.dispatcher")
    store_sup = Process.whereis(:"sup_t1d.store_supervisor")

    Process.exit(StoreSupervisor.whereis(store_sup, :data_store), :kill)
    Process.sleep(50)

    assert Process.whereis(:"sup_t1d.dispatcher") == dispatcher
    assert {:ok, [%{type: :log}]} = Anemos.Runtime.dispatch(:sup_t1d, "MOTION")
  end

  test "killing the subscribable registry does not kill the dispatcher" do
    start_runtime(:sup_t1e)
    dispatcher = Process.whereis(:"sup_t1e.dispatcher")
    store_sup = Process.whereis(:"sup_t1e.store_supervisor")

    Process.exit(StoreSupervisor.whereis(store_sup, :subscribable_registry), :kill)
    Process.sleep(50)

    assert Process.whereis(:"sup_t1e.dispatcher") == dispatcher
    assert {:ok, [%{type: :log}]} = Anemos.Runtime.dispatch(:sup_t1e, "MOTION")
  end

  test "killing a condition server does not kill the dispatcher" do
    start_supervised!({Anemos.Runtime, name: :sup_t1f})

    :ok =
      Anemos.Runtime.load(:sup_t1f, """
      condition daytime {
        when SUNRISE {
          log "up"
        }
      }
      """)

    dispatcher = Process.whereis(:"sup_t1f.dispatcher")
    store_sup = Process.whereis(:"sup_t1f.store_supervisor")
    cond_pid = StoreSupervisor.whereis(store_sup, {:condition, "daytime"})
    assert is_pid(cond_pid)

    Process.exit(cond_pid, :kill)
    Process.sleep(50)

    assert Process.whereis(:"sup_t1f.dispatcher") == dispatcher
    assert is_pid(StoreSupervisor.whereis(store_sup, {:condition, "daytime"}))
  end

  # --- Task 2: policies survive a dispatcher restart ---

  test "policy survives a dispatcher kill" do
    start_runtime(:sup_t2)

    dispatcher = Process.whereis(:"sup_t2.dispatcher")
    Process.exit(dispatcher, :kill)
    new_dispatcher = await_restart(:"sup_t2.dispatcher", dispatcher)

    refute new_dispatcher == dispatcher

    assert {:ok, [%{type: :log, value: "motion"}]} = Anemos.Runtime.dispatch(:sup_t2, "MOTION"),
           "policy was silently lost across a dispatcher restart"
  end

  test "conditions and capabilities survive a dispatcher kill" do
    start_supervised!({Anemos.Runtime, name: :sup_t2b})

    :ok =
      Anemos.Runtime.load(:sup_t2b, """
      condition motionseen {
        when MOTION {
          log "seen"
        }
      }

      rule react {
        when CONDITION_motionseen {
          log "reacted"
        }
      }
      """)

    assert {:ok, results} = Anemos.Runtime.dispatch(:sup_t2b, "MOTION")
    assert Enum.any?(results, &match?(%{type: :log, value: "reacted"}, &1))

    dispatcher = Process.whereis(:"sup_t2b.dispatcher")
    Process.exit(dispatcher, :kill)
    await_restart(:"sup_t2b.dispatcher", dispatcher)

    assert {:ok, results} = Anemos.Runtime.dispatch(:sup_t2b, "MOTION")

    assert Enum.any?(results, &match?(%{type: :log, value: "reacted"}, &1)),
           "condition/capability wiring was lost across a dispatcher restart"
  end

  test "policy survives a store supervisor kill" do
    start_runtime(:sup_t2c)

    store_sup = Process.whereis(:"sup_t2c.store_supervisor")
    dispatcher = Process.whereis(:"sup_t2c.dispatcher")
    Process.exit(store_sup, :kill)

    await_restart(:"sup_t2c.store_supervisor", store_sup)
    # rest_for_one: the dispatcher is restarted behind the store supervisor
    if Process.whereis(:"sup_t2c.dispatcher") == dispatcher do
      Process.sleep(50)
    else
      await_restart(:"sup_t2c.dispatcher", dispatcher)
    end

    assert {:ok, [%{type: :log}]} = Anemos.Runtime.dispatch(:sup_t2c, "MOTION")
  end

  test "policy survives a policy store kill only if the store is the source of truth" do
    start_runtime(:sup_t2d)

    policy_store = Process.whereis(:"sup_t2d.policy_store")
    assert is_pid(policy_store)
    assert [_ | _] = Anemos.Runtime.PolicyStore.all(policy_store)
  end

  # --- Task 4: Anemos.run/2 must not leak processes ---

  test "Anemos.run/2 leaks no processes" do
    source = ~s|rule t { when EV { log "hi" } }|
    # warm up so one-off lazy processes are not counted
    {:ok, _} = Anemos.run(source, event: "EV")
    Process.sleep(20)

    before = length(Process.list())

    for _ <- 1..20 do
      {:ok, _} = Anemos.run(source, event: "EV")
    end

    Process.sleep(50)
    after_count = length(Process.list())

    assert after_count - before <= 2,
           "Anemos.run/2 leaked #{after_count - before} processes over 20 calls"
  end

  test "Anemos.run/2 with conditions and capabilities leaks no processes" do
    source = """
    condition c { when EV { log "c" } }
    capability k { on demand { log "k" } }
    rule t { when EV { log "hi" } }
    """

    {:ok, _} = Anemos.run(source, event: "EV")
    Process.sleep(20)
    before = length(Process.list())

    for _ <- 1..20 do
      {:ok, _} = Anemos.run(source, event: "EV")
    end

    Process.sleep(50)
    after_count = length(Process.list())

    assert after_count - before <= 2,
           "Anemos.run/2 leaked #{after_count - before} processes over 20 calls"
  end
end

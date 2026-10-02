defmodule Anemos.Runtime.RestartStateTest do
  @moduledoc """
  A-40 to A-43, and the scheduler: what a runtime has accumulated survives
  the restart of the process that was holding it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anemos.Runtime
  alias Anemos.Runtime.{Scheduler, StoreSupervisor}

  defmodule Echo do
    @moduledoc false
    @behaviour Anemos.Runtime.Module

    @impl true
    def handle_verb(verb, _args, _context), do: {:ok, "echo:#{verb}"}
  end

  setup context do
    name = :"rs_#{:erlang.phash2(context.test)}"
    start_supervised!({Runtime, name: name})
    %{rt: name}
  end

  defp logs(rt, event, context \\ %{}) do
    {:ok, results} = Runtime.dispatch(rt, event, context)
    for %{type: :log, value: value} <- results, do: value
  end

  # Kills the registered process and waits for its supervisor to bring a
  # different one back under the same name.
  defp restart(name) do
    old = Process.whereis(name)
    ref = Process.monitor(old)
    Process.exit(old, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}
    await(fn -> Process.whereis(name) not in [nil, old] end)
  end

  defp await(fun, tries \\ 200) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(10) && await(fun, tries - 1)
    end
  end

  test "A-40: set bindings survive a dispatcher restart", %{rt: rt} do
    :ok = Runtime.load(rt, ~s|rule count { when TICK { log $seen\n set seen = "yes" } }|)
    assert logs(rt, "TICK") == [nil]

    restart(:"#{rt}.dispatcher")

    assert logs(rt, "TICK") == ["yes"]
  end

  test "A-41: an armed dwell timer still fires after a dispatcher restart, on its deadline",
       %{rt: rt} do
    :ok = Runtime.load(rt, ~s|rule r { when EV for 300ms { log "dwelt" } }|)

    started = System.monotonic_time(:millisecond)
    Runtime.dispatch(rt, "EV")

    early =
      capture_log(fn ->
        Process.sleep(100)
        restart(:"#{rt}.dispatcher")
        Process.sleep(max(0, 220 - (System.monotonic_time(:millisecond) - started)))
      end)

    refute early =~ "dwelt", "the restart fired the timer before its deadline"

    late = capture_log(fn -> Process.sleep(250) end)

    assert length(String.split(late, "dwelt")) == 2, "expected the dwell body to run exactly once"
  end

  test "A-42: a true condition is still true after a dispatcher restart, and does not re-fire",
       %{rt: rt} do
    :ok =
      Runtime.load(rt, """
      condition hot { when TEMP { log "c" } }
      rule onhot { when CONDITION_hot { log "fired" } }
      """)

    assert "fired" in logs(rt, "TEMP")

    restart(:"#{rt}.dispatcher")

    assert Runtime.condition_state(rt, "hot") == true
    refute "fired" in logs(rt, "TEMP")
  end

  test "A-42: a condition server that crashes comes back with its state", %{rt: rt} do
    :ok = Runtime.load(rt, ~s|condition hot { when TEMP { log "c" } }|)
    Runtime.dispatch(rt, "TEMP")

    stores = :"#{rt}.store_supervisor"
    old = StoreSupervisor.whereis(stores, {:condition, "hot"})
    Process.exit(old, :kill)
    await(fn -> StoreSupervisor.whereis(stores, {:condition, "hot"}) not in [nil, old] end)

    assert Runtime.condition_state(rt, "hot") == true
  end

  test "an anonymous reload of a condition still resets it", %{rt: rt} do
    source = ~s|condition hot { when TEMP { log "c" } }|
    :ok = Runtime.load(rt, source)
    Runtime.dispatch(rt, "TEMP")

    :ok = Runtime.load(rt, source)

    assert Runtime.condition_state(rt, "hot") == false
  end

  test "A-43: module registrations survive a registry restart", %{rt: rt} do
    :ok = Runtime.register(rt, "ECHO", Echo)
    :ok = Runtime.load(rt, ~s|rule r { when EV { log [ECHO::hello] } }|)
    assert logs(rt, "EV") == ["echo:hello"]

    restart(:"#{rt}.registry")
    await(fn -> Process.whereis(:"#{rt}.dispatcher") != nil end)

    assert logs(rt, "EV") == ["echo:hello"]
  end

  test "schedules are armed again after the scheduler restarts", %{rt: rt} do
    :ok = Runtime.load(rt, ~s|rule r { at 08:00 { log "t" } }|)
    scheduler = :"#{rt}.scheduler"
    assert [%{event_name: name}] = Scheduler.schedules(scheduler)

    restart(:"#{rt}.dispatcher")
    await(fn -> Process.whereis(scheduler) != nil end)

    assert [%{event_name: ^name}] = Scheduler.schedules(scheduler)
  end

  test "state does not outlive the rule that made it", %{rt: rt} do
    counter = ~s|rule count { when TICK { log $seen\n set seen = "yes" } }|
    :ok = Runtime.load(rt, counter, policy: "p")
    logs(rt, "TICK")
    :ok = Runtime.unload(rt, "p")

    restart(:"#{rt}.dispatcher")
    :ok = Runtime.load(rt, counter, policy: "p")

    assert logs(rt, "TICK") == [nil]
  end
end

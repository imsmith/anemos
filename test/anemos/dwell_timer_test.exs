defmodule Anemos.DwellTimerTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias Anemos.{Parser, Compiler}
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  defp setup_runtime(source) do
    {:ok, ast} = Parser.parse(source)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: compiled.rules, registry: registry)
    dispatcher
  end

  defp log_values(results) do
    results
    |> List.flatten()
    |> Enum.flat_map(fn
      {:ok, %{type: :log, value: v}} -> [v]
      _ -> []
    end)
  end

  test "armed timer fires after duration with single truthy arrival" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 50ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(120)
      end)

    assert log =~ "fired"
  end

  test "second truthy arrival does NOT restart the timer" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 200ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    elapsed_ref = :counters.new(1, [:atomics])

    log =
      capture_log(fn ->
        t0 = System.monotonic_time(:millisecond)
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        # 120ms in, send another arrival. If timer restarted, fire would happen
        # at t=320ms. If timer does NOT restart, fire at t=200ms.
        Process.sleep(120)
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        # Wait until t=260ms — past the 200ms expiry, well before any 320ms.
        Process.sleep(140)
        t1 = System.monotonic_time(:millisecond)
        :counters.put(elapsed_ref, 1, t1 - t0)
      end)

    elapsed = :counters.get(elapsed_ref, 1)
    assert elapsed >= 260 and elapsed < 350
    assert log =~ "fired"
  end

  test "falsy-payload arrival in armed state cancels the timer (body never fires)" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 100ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(30)
        # Falsy payload — cancels the timer.
        _ = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"state" => false}})
        # Wait well past the original expiry.
        Process.sleep(150)
      end)

    refute log =~ "fired"
  end

  test "falsy-payload arrival in listening state is a no-op (no timer started)" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 50ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"state" => false}})
        Process.sleep(100)
      end)

    refute log =~ "fired"
  end

  test "after firing, returns to listening (can re-arm)" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV for 50ms { log "fired" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(80)  # fires at ~50ms
        _ = Dispatcher.dispatch(dispatcher, "EV", %{})
        Process.sleep(80)  # fires again at ~130ms total
      end)

    fired_count =
      log
      |> String.split("fired")
      |> length()
      |> Kernel.-(1)

    assert fired_count == 2
  end

  test "two when blocks with different events get independent dwell state" do
    import ExUnit.CaptureLog

    src = """
    rule r {
      when EV1 for 50ms { log "one" }
      when EV2 for 50ms { log "two" }
    }
    """
    dispatcher = setup_runtime(src)

    log =
      capture_log(fn ->
        _ = Dispatcher.dispatch(dispatcher, "EV1", %{})
        _ = Dispatcher.dispatch(dispatcher, "EV2", %{})
        Process.sleep(100)
      end)

    assert log =~ "one"
    assert log =~ "two"
  end

  test "non-dwell rules (no for) still fire immediately" do
    src = """
    rule r {
      when EV { log "immediate" }
    }
    """
    dispatcher = setup_runtime(src)

    results = Dispatcher.dispatch(dispatcher, "EV", %{})
    assert log_values(results) == ["immediate"]
  end
end

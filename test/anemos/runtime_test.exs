defmodule Anemos.RuntimeTest do
  @moduledoc false
  use ExUnit.Case

  test "starts blank and loads a policy" do
    start_supervised!({Anemos.Runtime, name: :test_blank})

    Anemos.Runtime.register(:test_blank, "DEVICE", Anemos.Runtime.Modules.Device)

    :ok =
      Anemos.Runtime.load(:test_blank, """
      rule lights-on {
        when MOTION {
          [DEVICE::set "light" "on"]
        }
      }
      """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_blank, "MOTION")
    assert [%{module: "DEVICE", verb: "set", args: ["light", "on"]}] = results
  end

  test "non-matching event returns empty results" do
    start_supervised!({Anemos.Runtime, name: :test_no_match})

    Anemos.Runtime.load(:test_no_match, """
    rule lights-on {
      when MOTION {
        log "motion"
      }
    }
    """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_no_match, "OTHER")
    assert results == []
  end

  test "multiple policies accumulate" do
    start_supervised!({Anemos.Runtime, name: :test_accum})

    Anemos.Runtime.load(:test_accum, """
    rule a {
      when EVENT_A {
        log "a"
      }
    }
    """)

    Anemos.Runtime.load(:test_accum, """
    rule b {
      when EVENT_B {
        log "b"
      }
    }
    """)

    {:ok, results_a} = Anemos.Runtime.dispatch(:test_accum, "EVENT_A")
    log_a = for %{type: :log, value: v} <- results_a, do: v
    assert "a" in log_a

    {:ok, results_b} = Anemos.Runtime.dispatch(:test_accum, "EVENT_B")
    log_b = for %{type: :log, value: v} <- results_b, do: v
    assert "b" in log_b
  end

  test "modules can be registered dynamically" do
    start_supervised!({Anemos.Runtime, name: :test_dynmod})

    Anemos.Runtime.load(:test_dynmod, """
    rule use-device {
      when EV {
        [DEVICE::set "x" "y"]
      }
    }
    """)

    # Before registering module, command fails
    {:ok, results} = Anemos.Runtime.dispatch(:test_dynmod, "EV")
    assert [{:error, {:unknown_module, "DEVICE"}}] = results

    # Register module, now it works
    Anemos.Runtime.register(:test_dynmod, "DEVICE", Anemos.Runtime.Modules.Device)

    {:ok, results} = Anemos.Runtime.dispatch(:test_dynmod, "EV")
    assert [%{module: "DEVICE", verb: "set", args: ["x", "y"]}] = results
  end

  test "conditions work across dispatches" do
    start_supervised!({Anemos.Runtime, name: :test_cond})

    Anemos.Runtime.load(:test_cond, """
    condition active {
      when RAW_EVENT {
        log "activated"
      }
    }

    rule react {
      when CONDITION_active {
        log "condition fired"
      }
    }
    """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_cond, "RAW_EVENT")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "condition fired" in log_values
  end

  test "set bindings persist across dispatches" do
    start_supervised!({Anemos.Runtime, name: :test_persist})

    Anemos.Runtime.load(:test_persist, """
    rule counter {
      when TICK {
        set seen = "yes"
      }
      when CHECK {
        log $seen
      }
    }
    """)

    Anemos.Runtime.dispatch(:test_persist, "TICK")
    {:ok, results} = Anemos.Runtime.dispatch(:test_persist, "CHECK")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "yes" in log_values
  end

  test "context data is settable and resolvable" do
    start_supervised!({Anemos.Runtime, name: :test_ctx})

    Anemos.Runtime.put_context(:test_ctx, "name", "ian")

    Anemos.Runtime.load(:test_ctx, """
    rule greet {
      when GREET {
        log ?name
      }
    }
    """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_ctx, "GREET", %{context_data: %{"name" => "ian"}})
    assert [%{type: :log, value: "ian"}] = results
  end

  test "condition_state is queryable" do
    start_supervised!({Anemos.Runtime, name: :test_query})

    Anemos.Runtime.load(:test_query, """
    condition ready {
      when ACTIVATE {
        log "ready"
      }
    }

    rule noop {
      when NOOP {
        log "noop"
      }
    }
    """)

    assert Anemos.Runtime.condition_state(:test_query, "ready") == false
    Anemos.Runtime.dispatch(:test_query, "ACTIVATE")
    assert Anemos.Runtime.condition_state(:test_query, "ready") == true
  end

  test "demand resolves capabilities" do
    start_supervised!({Anemos.Runtime, name: :test_demand})

    Anemos.Runtime.load(:test_demand, """
    capability test-cap {
      context test

      on demand {
        log "cap executed"
      }
    }

    rule use-cap {
      when DO_IT {
        demand test-cap
        log "after demand"
      }
    }
    """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_demand, "DO_IT")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "cap executed" in log_values
    assert "after demand" in log_values
  end

  test "load returns error for invalid source" do
    start_supervised!({Anemos.Runtime, name: :test_err})

    assert {:error, _} = Anemos.Runtime.load(:test_err, "rule { broken")
  end

  test "at interval fires through runtime" do
    start_supervised!({Anemos.Runtime, name: :test_at_rt})

    Anemos.Runtime.load(:test_at_rt, """
    rule tick {
      at interval(50ms) {
        log "tick"
      }
    }
    """)

    # Give the interval time to fire
    Process.sleep(150)

    # Verify scheduler process is running
    assert Process.alive?(Process.whereis(:"test_at_rt.scheduler"))
  end
end

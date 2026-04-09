defmodule Anemos.RuntimeTest do
  @moduledoc false
  use ExUnit.Case

  test "starts and dispatches events" do
    source = """
    rule lights-on {
      when MOTION {
        [DEVICE::set "light" "on"]
      }
    }
    """

    start_supervised!(
      {Anemos.Runtime,
       name: :test_basic,
       source: source,
       modules: %{"DEVICE" => Anemos.Runtime.Modules.Device}}
    )

    {:ok, results} = Anemos.Runtime.dispatch(:test_basic, "MOTION")
    assert [%{module: "DEVICE", verb: "set", args: ["light", "on"]}] = results
  end

  test "non-matching event returns empty results" do
    source = """
    rule lights-on {
      when MOTION {
        [DEVICE::set "light" "on"]
      }
    }
    """

    start_supervised!(
      {Anemos.Runtime,
       name: :test_no_match,
       source: source,
       modules: %{"DEVICE" => Anemos.Runtime.Modules.Device}}
    )

    {:ok, results} = Anemos.Runtime.dispatch(:test_no_match, "OTHER")
    assert results == []
  end

  test "conditions work across dispatches" do
    source = """
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
    """

    start_supervised!({Anemos.Runtime, name: :test_cond, source: source})

    {:ok, results} = Anemos.Runtime.dispatch(:test_cond, "RAW_EVENT")

    log_values = for %{type: :log, value: v} <- results, do: v
    assert "condition fired" in log_values
  end

  test "set bindings persist across dispatches" do
    source = """
    rule counter {
      when TICK {
        set seen = "yes"
      }
      when CHECK {
        log $seen
      }
    }
    """

    start_supervised!({Anemos.Runtime, name: :test_persist, source: source})

    Anemos.Runtime.dispatch(:test_persist, "TICK")
    {:ok, results} = Anemos.Runtime.dispatch(:test_persist, "CHECK")

    log_values = for %{type: :log, value: v} <- results, do: v
    assert "yes" in log_values
  end

  test "context_data resolves ? variables" do
    source = """
    rule greet {
      when GREET {
        log ?name
      }
    }
    """

    start_supervised!(
      {Anemos.Runtime,
       name: :test_ctx,
       source: source,
       context_data: %{"name" => "ian"}}
    )

    {:ok, results} = Anemos.Runtime.dispatch(:test_ctx, "GREET", %{context_data: %{"name" => "ian"}})
    assert [%{type: :log, value: "ian"}] = results
  end

  test "condition_state is queryable" do
    source = """
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
    """

    start_supervised!({Anemos.Runtime, name: :test_query, source: source})

    assert Anemos.Runtime.condition_state(:test_query, "ready") == false
    Anemos.Runtime.dispatch(:test_query, "ACTIVATE")
    assert Anemos.Runtime.condition_state(:test_query, "ready") == true
  end

  test "demand resolves capabilities" do
    source = """
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
    """

    start_supervised!({Anemos.Runtime, name: :test_demand, source: source})

    {:ok, results} = Anemos.Runtime.dispatch(:test_demand, "DO_IT")

    log_values = for %{type: :log, value: v} <- results, do: v
    assert "cap executed" in log_values
    assert "after demand" in log_values
  end
end

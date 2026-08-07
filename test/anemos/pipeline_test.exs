defmodule Anemos.PipelineTest do
  @moduledoc false
  use ExUnit.Case

  doctest Anemos

  test "end-to-end: parse → compile → dispatch → observe" do
    input = """
    rule garage-lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }
    """

    assert {:ok, results} = Anemos.run(input, event: "SENSOR_MOTION_DETECTED")
    assert [%{module: "DEVICE", verb: "set", args: ["garage.lights", "on"]}] = results
  end

  test "non-matching event returns empty results" do
    input = """
    rule garage-lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }
    """

    assert {:ok, []} = Anemos.run(input, event: "SOME_OTHER_EVENT")
  end

  test "parse error returns {:error, message}" do
    input = "rule { broken"

    assert {:error, message} = Anemos.run(input, event: "ANYTHING")
    assert is_binary(message)
  end

  test "end-to-end: condition triggers rule via synthetic event" do
    input = """
    condition networkchanged {
      when RAW_NETWORK_EVENT {
        log "condition side effect"
      }
    }

    rule react {
      when CONDITION_networkchanged {
        log "rule fired from condition"
      }
    }
    """

    assert {:ok, results} = Anemos.run(input, event: "RAW_NETWORK_EVENT")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "rule fired from condition" in log_values
  end

  test "end-to-end: demand invokes capability" do
    input = """
    capability test-cap {
      context test

      on demand {
        log "capability executed"
      }
    }

    rule use-cap {
      when TEST_EVENT {
        demand test-cap
        log "after demand"
      }
    }
    """

    assert {:ok, results} = Anemos.run(input, event: "TEST_EVENT")

    # `use-cap` declares no context, so it cannot reach a capability scoped
    # to `test` (A-07). The rule body still runs; only the demand is refused.
    # This assertion used to be `length(results) >= 1`, which passed either
    # way and so said nothing.
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "after demand" in log_values
    refute "capability executed" in log_values
  end

  test "ddns.rule: raw event -> condition -> rule with demand" do
    source = File.read!("priv/examples/ddns.rule")
    {:ok, ast} = Anemos.Parser.parse(source)
    {:ok, compiled} = Anemos.Compiler.compile(ast)

    # Verify all three declaration types compiled
    assert length(compiled.rules) == 1
    assert length(compiled.conditions) == 1
    assert length(compiled.capabilities) == 1

    assert hd(compiled.rules).name == "update-ddns"
    assert hd(compiled.conditions).name == "networkchanged"
    assert hd(compiled.capabilities).name == "katachora-ddns-key"

    # Verify condition subscribes to the right events
    cond_subs = hd(compiled.conditions).subscriptions
    assert Enum.any?(cond_subs, &String.contains?(&1, "ip4"))
    assert Enum.any?(cond_subs, &String.contains?(&1, "ip6"))

    # Verify rule subscribes to CONDITION_networkchanged
    assert "CONDITION_networkchanged" in hd(compiled.rules).subscriptions
  end

  test "? variables resolve from context_data option" do
    input = """
    rule greet {
      when GREET {
        log ?name
      }
    }
    """

    context = %{context_data: %{"name" => "ian"}}
    {:ok, results} = Anemos.run(input, event: "GREET", context: context)
    assert [%{type: :log, value: "ian"}] = results
  end

  test "? variables return nil when context_data key missing" do
    input = """
    rule greet {
      when GREET {
        log ?missing
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "GREET", context: %{context_data: %{}})
    assert [%{type: :log, value: nil}] = results
  end

  test "multi-rule file with specific event only fires matching rules" do
    input = """
    rule lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }

    rule save-log {
      when FILE_CHANGED {
        [FILE::write "/tmp/log" "changed"]
      }
    }
    """

    assert {:ok, results} = Anemos.run(input, event: "SENSOR_MOTION_DETECTED")
    assert length(results) == 1
    assert [%{module: "DEVICE", verb: "set", args: ["garage.lights", "on"]}] = results

    assert {:ok, results} = Anemos.run(input, event: "FILE_CHANGED")
    assert length(results) == 1
    assert [%{module: "FILE", verb: "write", args: ["/tmp/log", "changed"]}] = results
  end

  test "end-to-end: for loop with return exits early" do
    input = """
    rule scan {
      when SCAN {
        for item in ?items {
          if @item == "stop" {
            return
          }
          log @item
        }
      }
    }
    """

    context = %{context_data: %{"items" => ["a", "b", "stop", "c"]}}
    {:ok, results} = Anemos.run(input, event: "SCAN", context: context)
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["a", "b"]
  end

  test "end-to-end: nextevent chains within same rule" do
    input = """
    rule pipeline {
      when START {
        log "phase-1"
        nextevent PHASE_TWO
      }

      when PHASE_TWO {
        log "phase-2"
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "START")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert "phase-1" in log_values
    assert "phase-2" in log_values
  end

  test "end-to-end: while loop with set tracks state" do
    input = """
    rule accumulate {
      when TICK {
        set total = 0
        set i = 1
        while $i <= 5 {
          set total = $total + $i
          set i = $i + 1
        }
        log $total
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "TICK")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [15]
  end

  test "end-to-end: nested for and if with commands" do
    input = """
    rule process {
      when BATCH {
        for item in ?items {
          if @item != "skip" {
            [FILE::write @item "processed"]
          }
        }
      }
    }
    """

    context = %{context_data: %{"items" => ["a", "skip", "b"]}}
    {:ok, results} = Anemos.run(input, event: "BATCH", context: context)
    commands = for %{module: "FILE", verb: "write", args: args} <- results, do: args
    assert commands == [["a", "processed"], ["b", "processed"]]
  end
end

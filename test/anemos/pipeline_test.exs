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
    # Results include both capability output and rule output
    assert length(results) >= 1
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
end

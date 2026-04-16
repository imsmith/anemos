defmodule Anemos.Runtime.DispatcherTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}
  alias Anemos.{Parser, Compiler}

  doctest Anemos.Runtime.ModuleRegistry

  test "dispatches event to matching rule and executes operations" do
    input = """
    rule test-dispatch {
      when TEST_EVENT {
        [DEVICE::set "light" "on"]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, registry} = ModuleRegistry.start_link([])
    ModuleRegistry.register(registry, "DEVICE", Anemos.TestModules.Device)

    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "TEST_EVENT")
    assert [{:ok, _}] = results
  end

  test "event dispatched to rule that doesn't subscribe to it returns no results" do
    input = """
    rule no-match {
      when OTHER_EVENT {
        [DEVICE::set "light" "off"]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, registry} = ModuleRegistry.start_link([])
    ModuleRegistry.register(registry, "DEVICE", Anemos.TestModules.Device)

    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "UNRELATED_EVENT")
    assert results == []
  end

  test "multiple rules subscribing to same event both fire" do
    input = """
    rule rule-a {
      when SHARED_EVENT {
        [DEVICE::set "light" "on"]
      }
    }

    rule rule-b {
      when SHARED_EVENT {
        [DEVICE::set "fan" "off"]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: compiled_rules}} = Compiler.compile(ast)

    {:ok, registry} = ModuleRegistry.start_link([])
    ModuleRegistry.register(registry, "DEVICE", Anemos.TestModules.Device)

    {:ok, dispatcher} = Dispatcher.start_link(rules: compiled_rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "SHARED_EVENT")
    assert length(results) == 2

    assert Enum.all?(results, fn
             {:ok, _} -> true
             _ -> false
           end)
  end

  test "log operations are collected in results" do
    input = """
    rule log-rule {
      when LOG_EVENT {
        log "hello world"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "LOG_EVENT")
    assert [{:ok, %{type: :log, value: "hello world"}}] = results
  end

  test "log operations emit through Logger" do
    input = """
    rule log-test {
      when LOG_EVENT {
        log "hello from anemos"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        results = Dispatcher.dispatch(dispatcher, "LOG_EVENT")
        assert [{:ok, %{type: :log, value: "hello from anemos"}}] = results
      end)

    assert log =~ "hello from anemos"
  end

  test "unknown module in operation returns error result" do
    input = """
    rule unknown-mod {
      when UNKNOWN_EVENT {
        [NOEXIST::do "something"]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "UNKNOWN_EVENT")
    assert [{:error, _}] = results
  end

  test "registry with no modules registered returns error for command ops" do
    input = """
    rule empty-registry {
      when EMPTY_EVENT {
        [DEVICE::set "light" "on"]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "EMPTY_EVENT")
    assert [{:error, _}] = results
  end

  test "handler crash does not kill dispatcher" do
    crash_rule = %{
      name: "crash-rule",
      subscriptions: ["CRASH_EVENT"],
      handler: fn _event, _ctx, _persistent -> raise "boom" end
    }

    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [crash_rule], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "CRASH_EVENT")
    assert [{:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/handler_crash"}}] = results

    # Dispatcher still alive
    assert Process.alive?(dispatcher)
  end

  # --- Condition integration ---

  test "condition server triggers CONDITION_<name> event to matching rules" do
    rule_input = """
    rule react-to-condition {
      when CONDITION_networkchanged {
        log "network changed!"
      }
    }
    """

    {:ok, ast} = Parser.parse(rule_input)
    {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: [compiled_rule],
        registry: registry,
        conditions: [
          %Anemos.CompiledCondition{
            name: "networkchanged",
            subscriptions: ["RAW_EVENT"],
            evaluator: fn _event, _ctx -> true end,
            side_effects: []
          }
        ]
      )

    results = Dispatcher.dispatch(dispatcher, "RAW_EVENT")
    assert [{:ok, %{type: :log, value: "network changed!"}}] = results
  end

  test "condition that stays false does not trigger rules" do
    rule_input = """
    rule react-to-condition {
      when CONDITION_never_true {
        log "should not fire"
      }
    }
    """

    {:ok, ast} = Parser.parse(rule_input)
    {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: [compiled_rule],
        registry: registry,
        conditions: [
          %Anemos.CompiledCondition{
            name: "never_true",
            subscriptions: ["RAW_EVENT"],
            evaluator: fn _event, _ctx -> false end,
            side_effects: []
          }
        ]
      )

    results = Dispatcher.dispatch(dispatcher, "RAW_EVENT")
    assert results == []
  end

  test "condition queryable via dispatcher" do
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: [],
        registry: registry,
        conditions: [
          %Anemos.CompiledCondition{
            name: "test_cond",
            subscriptions: ["EV"],
            evaluator: fn _event, _ctx -> true end,
            side_effects: []
          }
        ]
      )

    assert Dispatcher.condition_state(dispatcher, "test_cond") == false
    Dispatcher.dispatch(dispatcher, "EV")
    assert Dispatcher.condition_state(dispatcher, "test_cond") == true
  end

  # --- Demand integration ---

  test "demand operation invokes capability server and returns result" do
    input = """
    rule demand-test {
      when TEST_EVENT {
        demand test-cap
        log "after demand"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: [compiled_rule],
        registry: registry,
        capabilities: [
          %Anemos.CompiledCapability{
            name: "test-cap",
            context: "test",
            handler: fn _ctx -> {:ok, [%{type: :emit, value: "cap-result"}]} end
          }
        ]
      )

    results = Dispatcher.dispatch(dispatcher, "TEST_EVENT")
    # Should have capability result + log
    assert length(results) >= 2
    values = Enum.map(results, fn {:ok, v} -> v end)
    assert Enum.any?(values, &match?(%{type: :emit, value: "cap-result"}, &1))
    assert Enum.any?(values, &match?(%{type: :log, value: "after demand"}, &1))
  end

  # --- Context filtering ---

  test "rule with context only fires for events in that context" do
    input = """
    rule scoped {
      context "garage.motion" {
        when SENSOR_MOTION_DETECTED {
          log "motion in garage"
        }
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    # Event with matching context fires the rule
    results = Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{context_path: "garage.motion"})
    assert [{:ok, %{type: :log, value: "motion in garage"}}] = results

    # Event with wrong context does not fire
    results = Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{context_path: "kitchen.motion"})
    assert results == []
  end

  test "rule with context fires for events in child context" do
    input = """
    rule scoped {
      context "infra.networking" {
        when NETWORK_EVENT {
          log "network"
        }
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "NETWORK_EVENT", %{context_path: "infra.networking.dns"})
    assert [{:ok, %{type: :log, value: "network"}}] = results
  end

  test "rule without context fires for any event regardless of context" do
    input = """
    rule global {
      when GLOBAL_EVENT {
        log "global"
      }
    }
    """
    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "GLOBAL_EVENT", %{context_path: "any.path"})
    assert [{:ok, %{type: :log, value: "global"}}] = results
  end

  test "demand for missing capability returns error" do
    input = """
    rule demand-missing {
      when TEST_EVENT {
        demand nonexistent
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled_rule]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: [compiled_rule],
        registry: registry,
        capabilities: []
      )

    results = Dispatcher.dispatch(dispatcher, "TEST_EVENT")
    assert [{:error, {:unknown_capability, "nonexistent"}}] = results
  end

  # --- Set persistence ---

  test "set bindings persist across firings" do
    input = """
    rule counter {
      when TICK {
        set count = 1
        log $count
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    # First firing: set count = 1
    results1 = Dispatcher.dispatch(dispatcher, "TICK")

    assert Enum.any?(results1, fn
      {:ok, %{type: :log, value: 1}} -> true
      _ -> false
    end)

    # Second firing: $count is available from persistent state
    results2 = Dispatcher.dispatch(dispatcher, "TICK")

    assert Enum.any?(results2, fn
      {:ok, %{type: :log, value: 1}} -> true
      _ -> false
    end)
  end

  test "set bindings are readable via $ in subsequent firings" do
    input = """
    rule stateful {
      when PING {
        set seen = "yes"
      }
      when CHECK {
        log $seen
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: rules}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: rules, registry: registry)

    # First: set the value
    Dispatcher.dispatch(dispatcher, "PING")

    # Second: read it back in a different when block
    results = Dispatcher.dispatch(dispatcher, "CHECK")

    assert Enum.any?(results, fn
      {:ok, %{type: :log, value: "yes"}} -> true
      _ -> false
    end)
  end

  # --- Emit label re-dispatch ---

  test "emit with label dispatches label as event" do
    input = """
    rule emitter {
      when SOURCE_EVENT {
        emit [EVENT::fire] as :my.event
      }
    }

    rule listener {
      when my.event {
        log "received emit"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: rules}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "SOURCE_EVENT")

    log_values =
      Enum.flat_map(results, fn
        {:ok, %{type: :log, value: v}} -> [v]
        _ -> []
      end)

    assert "received emit" in log_values
  end

  test "emit without label returns op as-is" do
    input = """
    rule emitter {
      when SOURCE_EVENT {
        emit [EVENT::fire]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [compiled], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "SOURCE_EVENT")
    assert [{:ok, %{type: :emit}}] = results
  end

  # --- DataStore integration ---

  test "dispatcher registers data blocks and supports data_member?" do
    {:ok, registry} = Anemos.Runtime.ModuleRegistry.start_link([])

    input = """
    data test-set {
      alpha
      bravo
    }
    rule r {
      when EV {
        log "ok"
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)

    {:ok, dispatcher} =
      Anemos.Runtime.Dispatcher.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

    assert Anemos.Runtime.Dispatcher.data_member?(dispatcher, "test-set", "alpha")
    assert Anemos.Runtime.Dispatcher.data_member?(dispatcher, "test-set", "bravo")
    refute Anemos.Runtime.Dispatcher.data_member?(dispatcher, "test-set", "unknown")
  end
end

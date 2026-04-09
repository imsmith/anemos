defmodule Anemos.Runtime.DispatcherTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}
  alias Anemos.{Parser, Compiler}

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
      handler: fn _event, _ctx -> raise "boom" end
    }

    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, dispatcher} = Dispatcher.start_link(rules: [crash_rule], registry: registry)

    results = Dispatcher.dispatch(dispatcher, "CRASH_EVENT")
    assert [{:error, {:handler_crash, "crash-rule", _}}] = results

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
end

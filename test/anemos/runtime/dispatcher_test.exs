defmodule Anemos.Runtime.DispatcherTest do
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
    {:ok, [compiled]} = Compiler.compile(ast)

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
    {:ok, [compiled]} = Compiler.compile(ast)

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
    {:ok, compiled_rules} = Compiler.compile(ast)

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
    {:ok, [compiled]} = Compiler.compile(ast)

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
    {:ok, [compiled]} = Compiler.compile(ast)

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
    {:ok, [compiled]} = Compiler.compile(ast)

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
end

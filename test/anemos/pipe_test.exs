defmodule Anemos.PipeIntegrationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  test "pipe with filter dispatches correctly" do
    input = """
    rule process {
      when BATCH {
        let filtered = ?scores |> filter ?s (?s > 50)
        log @filtered
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "BATCH", %{context_data: %{"scores" => [10, 60, 30, 80, 45]}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == [60, 80]
  end

  test "chained pipeline: filter then map then reduce" do
    input = """
    rule analyze {
      when DATA {
        let result = ?values |> filter ?x (?x > 0) |> map ?x (?x * 2) |> reduce sum 0 ?x ($sum + ?x)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "DATA", %{context_data: %{"values" => [-1, 2, -3, 4, 5]}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    # filter: [2, 4, 5], map: [4, 8, 10], reduce: 22
    assert log_op.value == 22
  end

  test "pipe with non-list wraps single value" do
    input = """
    rule wrap {
      when EV {
        let result = ?single |> filter ?x (?x > 0)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"single" => 5}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == [5]
  end

  test "pipe with empty collection" do
    input = """
    rule empty {
      when EV {
        let result = ?items |> filter ?x (?x > 0) |> map ?x (?x * 10)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"items" => []}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == []
  end

  test "map only pipeline" do
    input = """
    rule double {
      when EV {
        let result = ?nums |> map ?n (?n * 2)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"nums" => [1, 2, 3]}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == [2, 4, 6]
  end

  test "reduce only pipeline" do
    input = """
    rule sum-up {
      when EV {
        let result = ?nums |> reduce total 0 ?n ($total + ?n)
        log @result
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(rules: compiled.rules, registry: registry)

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"nums" => [10, 20, 30]}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    log_op = Enum.find(ops, &(&1.type == :log))
    assert log_op.value == 60
  end
end

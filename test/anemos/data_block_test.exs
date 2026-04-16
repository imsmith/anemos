defmodule Anemos.DataBlockTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Parser, Compiler}
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  test "memberof() checks membership in data block" do
    input = """
    data allowed-users {
      alice
      bob
      charlie
    }
    rule check-user {
      when USER_LOGIN {
        if ?user memberof(allowed-users) {
          log "allowed"
        } else {
          log "denied"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Dispatcher.load(dispatcher, compiled)

    # alice is in allowed-users
    results = Dispatcher.dispatch(dispatcher, "USER_LOGIN", %{context_data: %{"user" => "alice"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "allowed"))

    # eve is NOT in allowed-users
    results = Dispatcher.dispatch(dispatcher, "USER_LOGIN", %{context_data: %{"user" => "eve"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "denied"))
  end

  test "memberof() with multiple set names (union check)" do
    input = """
    data set-a {
      alpha
    }
    data set-b {
      bravo
    }
    rule check {
      when EV {
        if ?val memberof(set-a, set-b) {
          log "found"
        } else {
          log "missing"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Dispatcher.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Dispatcher.load(dispatcher, compiled)

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"val" => "bravo"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "found"))

    results = Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"val" => "charlie"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "missing"))
  end
end

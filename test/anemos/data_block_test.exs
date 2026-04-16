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

  test "parses and compiles the stop-data-extraction policy pattern" do
    input = """
    data reserved-ips {
      alpha
      bravo
      charlie
    }

    data historical-tlds {
      su
      yu
      cs
    }

    rule block-reserved-ips {
      when CONNECTION_INIT {
        if ?src_ip memberof(reserved-ips) {
          log "blocked"
        }
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, result} = Anemos.Compiler.compile(ast)

    assert length(result.data_blocks) == 2
    assert length(result.rules) == 1

    reserved = Enum.find(result.data_blocks, &(&1.name == "reserved-ips"))
    assert MapSet.member?(reserved.dataset, "alpha")

    tlds = Enum.find(result.data_blocks, &(&1.name == "historical-tlds"))
    assert MapSet.member?(tlds.dataset, "su")
  end

  test "full dispatch with memberof against data block" do
    input = """
    data bad-ips {
      badhost
      evilhost
    }

    rule check {
      when CONN {
        if ?ip memberof(bad-ips) {
          log "blocked"
        } else {
          log "allowed"
        }
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = Anemos.Runtime.ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Dispatcher.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

    # Bad IP — should be blocked
    results = Anemos.Runtime.Dispatcher.dispatch(dispatcher, "CONN", %{context_data: %{"ip" => "badhost"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "blocked"))

    # Good IP — should be allowed
    results = Anemos.Runtime.Dispatcher.dispatch(dispatcher, "CONN", %{context_data: %{"ip" => "goodhost"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "allowed"))
  end

  test "multiple data blocks with memberof union" do
    input = """
    data europe {
      france
      germany
      spain
    }

    data asia {
      japan
      korea
    }

    rule geo-check {
      when REQUEST {
        if ?country memberof(europe, asia) {
          log "allowed-region"
        } else {
          log "blocked-region"
        }
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = Anemos.Runtime.ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Dispatcher.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

    # Japan is in asia
    results = Anemos.Runtime.Dispatcher.dispatch(dispatcher, "REQUEST", %{context_data: %{"country" => "japan"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "allowed-region"))

    # brazil is in neither
    results = Anemos.Runtime.Dispatcher.dispatch(dispatcher, "REQUEST", %{context_data: %{"country" => "brazil"}})
    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "blocked-region"))
  end
end

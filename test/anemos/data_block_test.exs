defmodule Anemos.TestSubscribable do
  @moduledoc false
  @behaviour Anemos.Subscribable

  def start_link do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  @impl true
  def subscribe(_protocol, uri, callback) do
    Agent.update(__MODULE__, &Map.put(&1, uri, callback))
    {:ok, make_ref()}
  end

  @impl true
  def unsubscribe(_ref), do: :ok

  @impl true
  def periodic?, do: false

  @impl true
  def interval(_spec), do: 60_000

  @doc "Simulate incoming data push"
  def push(uri, data) do
    callback = Agent.get(__MODULE__, &Map.get(&1, uri))
    if callback, do: callback.(data)
  end
end

defmodule Anemos.DataBlockTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Parser, Compiler}
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry, SubscribableRegistry}

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
      Anemos.Runtime.Standalone.start_link(
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
      Anemos.Runtime.Standalone.start_link(
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
      Anemos.Runtime.Standalone.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

    # Bad IP — should be blocked
    results =
      Anemos.Runtime.Dispatcher.dispatch(dispatcher, "CONN", %{context_data: %{"ip" => "badhost"}})

    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "blocked"))

    # Good IP — should be allowed
    results =
      Anemos.Runtime.Dispatcher.dispatch(dispatcher, "CONN", %{
        context_data: %{"ip" => "goodhost"}
      })

    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "allowed"))
  end

  test "dynamic data block subscribes and updates on push" do
    {:ok, _} = Anemos.TestSubscribable.start_link()

    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, sub_registry} = SubscribableRegistry.start_link()
    :ok = SubscribableRegistry.register(sub_registry, "test-proto", Anemos.TestSubscribable)

    input = """
    data live-feed {
      dynamic {
        subscribe test-proto "test://feed"
      }
    }
    rule r {
      when EV { log "ok" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(
        rules: compiled.rules,
        registry: registry,
        subscribable_registry: sub_registry
      )

    :ok = Dispatcher.load(dispatcher, compiled)

    # Initially empty
    refute Dispatcher.data_member?(dispatcher, "live-feed", "new-threat")

    # Push data through the subscription
    Anemos.TestSubscribable.push("test://feed", ["new-threat", "bad-actor"])

    # Now it should be there
    assert Dispatcher.data_member?(dispatcher, "live-feed", "new-threat")
    assert Dispatcher.data_member?(dispatcher, "live-feed", "bad-actor")
  end

  test "dynamic data block with no handler logs warning and does not crash" do
    {:ok, registry} = ModuleRegistry.start_link([])
    {:ok, sub_registry} = SubscribableRegistry.start_link()

    input = """
    data missing-handler {
      dynamic {
        subscribe unknown-proto "test://nowhere"
      }
    }
    rule r {
      when EV { log "ok" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(
        rules: compiled.rules,
        registry: registry,
        subscribable_registry: sub_registry
      )

    # Should not crash even though no handler is registered, but the block
    # is inert and load/2 must say so rather than reporting :ok.
    assert {:error,
            [{:data_block, "missing-handler", {:no_subscribable_handler, "unknown-proto"}}]} =
             Dispatcher.load(dispatcher, compiled)

    # Data block exists but is empty
    refute Dispatcher.data_member?(dispatcher, "missing-handler", "anything")
  end

  test "register_subscribable via dispatcher client API" do
    {:ok, _} = Anemos.TestSubscribable.start_link()
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(
        rules: [],
        registry: registry
      )

    :ok = Dispatcher.register_subscribable(dispatcher, "test-proto", Anemos.TestSubscribable)

    input = """
    data api-feed {
      dynamic {
        subscribe test-proto "test://api"
      }
    }
    rule r {
      when EV { log "ok" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)
    :ok = Dispatcher.load(dispatcher, compiled)

    refute Dispatcher.data_member?(dispatcher, "api-feed", "item-1")

    Anemos.TestSubscribable.push("test://api", ["item-1"])
    assert Dispatcher.data_member?(dispatcher, "api-feed", "item-1")
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
      Anemos.Runtime.Standalone.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

    # Japan is in asia
    results =
      Anemos.Runtime.Dispatcher.dispatch(dispatcher, "REQUEST", %{
        context_data: %{"country" => "japan"}
      })

    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "allowed-region"))

    # brazil is in neither
    results =
      Anemos.Runtime.Dispatcher.dispatch(dispatcher, "REQUEST", %{
        context_data: %{"country" => "brazil"}
      })

    ops = for {:ok, op} <- List.flatten(results), do: op
    assert Enum.any?(ops, &(&1.type == :log && &1.value == "blocked-region"))
  end

  test "inline data blocks are scoped per-rule via rule name" do
    input = """
    rule rule-a {
      data my-set {
        alpha
      }
      when EV {
        if ?val memberof(my-set) {
          log "rule-a-hit"
        } else {
          log "rule-a-miss"
        }
      }
    }

    rule rule-b {
      data my-set {
        bravo
      }
      when EV {
        if ?val memberof(my-set) {
          log "rule-b-hit"
        } else {
          log "rule-b-miss"
        }
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = Anemos.Runtime.ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(
        rules: compiled.rules,
        registry: registry
      )

    :ok = Anemos.Runtime.Dispatcher.load(dispatcher, compiled)

    # "alpha" is in rule-a's my-set but not rule-b's
    results =
      Anemos.Runtime.Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"val" => "alpha"}})

    ops = for {:ok, op} <- List.flatten(results), do: op
    log_values = for %{type: :log, value: v} <- ops, do: v
    assert "rule-a-hit" in log_values
    assert "rule-b-miss" in log_values

    # "bravo" is in rule-b's my-set but not rule-a's
    results =
      Anemos.Runtime.Dispatcher.dispatch(dispatcher, "EV", %{context_data: %{"val" => "bravo"}})

    ops = for {:ok, op} <- List.flatten(results), do: op
    log_values = for %{type: :log, value: v} <- ops, do: v
    assert "rule-a-miss" in log_values
    assert "rule-b-hit" in log_values
  end
end

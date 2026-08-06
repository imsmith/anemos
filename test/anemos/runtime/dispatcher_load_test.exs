defmodule Anemos.Runtime.DispatcherLoadTest do
  @moduledoc """
  A-15: `load/2` appended rules with no dedup on name, so loading the same
  policy twice fired every rule in it twice, and there was no way to unload.
  """
  use ExUnit.Case, async: false

  alias Anemos.Runtime.{Dispatcher, StoreSupervisor}

  setup context do
    tag = context.test |> to_string() |> String.replace(~r/\W/, "_")
    name = :"dl_#{tag}"

    start_supervised!({Anemos.Runtime, name: name})
    %{runtime: name, dispatcher: :"#{name}.dispatcher"}
  end

  defp compile!(source) do
    {:ok, ast} = Anemos.Parser.parse(source)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    compiled
  end

  @policy """
  rule greet {
    when PING {
      log "pong"
    }
  }
  """

  test "loading the same policy twice does not double-fire its rules", %{dispatcher: d} do
    compiled = compile!(@policy)

    :ok = Dispatcher.load(d, compiled)
    assert length(Dispatcher.dispatch(d, "PING", %{})) == 1

    :ok = Dispatcher.load(d, compiled)

    assert length(Dispatcher.dispatch(d, "PING", %{})) == 1,
           "a re-loaded rule fired more than once — load/2 appended instead of replacing"
  end

  test "a redefined rule replaces the previous definition", %{dispatcher: d} do
    :ok = Dispatcher.load(d, compile!(@policy))

    :ok =
      Dispatcher.load(d, compile!("""
      rule greet {
        when PING {
          log "replaced"
        }
      }
      """))

    assert [{:ok, %{type: :log, value: "replaced"}}] = Dispatcher.dispatch(d, "PING", %{})
  end

  test "rules from different policies still accumulate", %{dispatcher: d} do
    :ok = Dispatcher.load(d, compile!(@policy))

    :ok =
      Dispatcher.load(d, compile!("""
      rule other {
        when PING {
          log "second"
        }
      }
      """))

    values =
      d
      |> Dispatcher.dispatch("PING", %{})
      |> Enum.map(fn {:ok, op} -> op.value end)
      |> Enum.sort()

    assert values == ["pong", "second"]
  end

  test "a rule with two when blocks on the same event survives a reload", %{dispatcher: d} do
    source = """
    rule multi {
      when PING {
        log "a"
      }
      when PING {
        log "b"
      }
    }
    """

    :ok = Dispatcher.load(d, compile!(source))
    assert length(Dispatcher.dispatch(d, "PING", %{})) == 2

    # Both `when` blocks share the rule name, so replacement is by name and
    # must bring back both — not one, and not four.
    :ok = Dispatcher.load(d, compile!(source))
    assert length(Dispatcher.dispatch(d, "PING", %{})) == 2
  end

  test "reloading a condition does not orphan its server", %{runtime: rt, dispatcher: d} do
    source = """
    condition busy {
      when PING {
        log "cond"
      }
    }
    """

    sup = :"#{rt}.store_supervisor"

    :ok = Dispatcher.load(d, compile!(source))
    first = StoreSupervisor.whereis(sup, {:condition, "busy"})
    assert is_pid(first)

    :ok = Dispatcher.load(d, compile!(source))
    second = StoreSupervisor.whereis(sup, {:condition, "busy"})

    assert is_pid(second)
    assert second != first
    refute Process.alive?(first), "the previous ConditionServer was left running and unreachable"
  end

  describe "unload" do
    test "unload/2 removes the named rules", %{dispatcher: d} do
      :ok = Dispatcher.load(d, compile!(@policy))
      assert length(Dispatcher.dispatch(d, "PING", %{})) == 1

      assert :ok = Dispatcher.unload(d, ["greet"])
      assert Dispatcher.dispatch(d, "PING", %{}) == []
    end

    test "unload/2 leaves other rules alone", %{dispatcher: d} do
      :ok = Dispatcher.load(d, compile!(@policy))

      :ok =
        Dispatcher.load(d, compile!("""
        rule other {
          when PING {
            log "second"
          }
        }
        """))

      assert :ok = Dispatcher.unload(d, ["greet"])
      assert [{:ok, %{value: "second"}}] = Dispatcher.dispatch(d, "PING", %{})
    end

    test "unload/2 on an unknown rule name is a no-op", %{dispatcher: d} do
      assert :ok = Dispatcher.unload(d, ["never-loaded"])
    end

    test "an unloaded rule stays unloaded across a dispatcher restart", %{
      runtime: rt,
      dispatcher: d
    } do
      :ok = Dispatcher.load(d, compile!(@policy))
      assert :ok = Dispatcher.unload(d, ["greet"])

      # The policy store is what a restarted dispatcher rebuilds from. If
      # unload only touched the derived view, the rule comes back.
      pid = Process.whereis(d)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

      wait_for_restart(d, pid)
      assert Dispatcher.dispatch(d, "PING", %{}) == []
      _ = rt
    end

    test "unload/2 drops the rule's inline data scope", %{runtime: rt, dispatcher: d} do
      :ok =
        Dispatcher.load(d, compile!("""
        rule scoped {
          data my-set {
            alpha
          }
          when PING {
            log "hit"
          }
        }
        """))

      data_store = StoreSupervisor.whereis(:"#{rt}.store_supervisor", :data_store)
      assert Anemos.Runtime.DataStore.member?(data_store, "my-set", "alpha", scope_hint: "scoped")

      assert :ok = Dispatcher.unload(d, ["scoped"])

      refute Anemos.Runtime.DataStore.member?(data_store, "my-set", "alpha", scope_hint: "scoped")
    end

    test "a reload keeps the rule's inline data scope", %{runtime: rt, dispatcher: d} do
      source = """
      rule scoped {
        data my-set {
          alpha
        }
        when PING {
          log "hit"
        }
      }
      """

      :ok = Dispatcher.load(d, compile!(source))
      :ok = Dispatcher.load(d, compile!(source))

      data_store = StoreSupervisor.whereis(:"#{rt}.store_supervisor", :data_store)

      # Replacement re-registers the block; purging the scope on replace
      # would delete what the incoming load had just written.
      assert Anemos.Runtime.DataStore.member?(data_store, "my-set", "alpha", scope_hint: "scoped")
    end

    test "rules/1 reports what is loaded", %{dispatcher: d} do
      assert Dispatcher.rules(d) == []

      :ok = Dispatcher.load(d, compile!(@policy))
      assert Dispatcher.rules(d) == ["greet"]

      assert :ok = Dispatcher.unload(d, ["greet"])
      assert Dispatcher.rules(d) == []
    end
  end

  defp wait_for_restart(name, old_pid, tries \\ 100) do
    case Process.whereis(name) do
      nil when tries > 0 ->
        Process.sleep(10)
        wait_for_restart(name, old_pid, tries - 1)

      ^old_pid when tries > 0 ->
        Process.sleep(10)
        wait_for_restart(name, old_pid, tries - 1)

      pid when is_pid(pid) ->
        pid

      _ ->
        flunk("dispatcher #{inspect(name)} did not restart")
    end
  end
end

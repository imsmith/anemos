defmodule Anemos.Runtime.ConditionSideEffectsTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A-50. A condition body's operations must reach the dispatcher's execution
  path, not vanish.

  The spec's §3.2 worked example is a condition whose entire body is an
  `emit` to a channel, so "the body produces operations and nothing runs
  them" is not a design choice — it is the construct not working.

  These tests also pin the two constraints on the wiring: the operations go
  through the same path rule results do, so an `emit ... as` from a
  condition body is still filtered by `context_matches?/2` on the receiving
  side, and the recursion ceiling still applies to a cycle entered from a
  condition.
  """

  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  defmodule Recorder do
    @moduledoc false
    @behaviour Anemos.Runtime.Module

    @impl true
    def handle_verb(verb, args, _context) do
      send(:condition_side_effect_recorder, {:verb, verb, args})
      {:ok, %{type: :command, module: "REC", verb: verb, args: args}}
    end
  end

  defp runtime(source, opts \\ []) do
    {:ok, ast} = Anemos.Parser.parse(source)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(
        [
          rules: compiled.rules,
          conditions: compiled.conditions,
          capabilities: compiled.capabilities,
          registry: registry
        ] ++ opts
      )

    {dispatcher, registry}
  end

  defp logs(results) do
    for {:ok, %{type: :log, value: v}} <- results, do: v
  end

  test "operations produced by a condition body are executed" do
    {dispatcher, _registry} =
      runtime("""
      condition networkchanged {
        when IP_CHANGED {
          log "condition side effect ran"
        }
      }
      """)

    results = Dispatcher.dispatch(dispatcher, "IP_CHANGED")
    assert "condition side effect ran" in logs(results)
  end

  test "a command in a condition body reaches its module" do
    Process.register(self(), :condition_side_effect_recorder)

    {dispatcher, registry} =
      runtime("""
      condition networkchanged {
        when IP_CHANGED {
          [REC::note "fired"]
        }
      }
      """)

    :ok = ModuleRegistry.register(registry, "REC", Recorder)

    Dispatcher.dispatch(dispatcher, "IP_CHANGED")
    assert_receive {:verb, "note", ["fired"]}
  end

  test "the triggering event's context data is visible to the body" do
    {dispatcher, _registry} =
      runtime("""
      condition networkchanged {
        when IP_CHANGED {
          log ?hostname
        }
      }
      """)

    results =
      Dispatcher.dispatch(dispatcher, "IP_CHANGED", %{context_data: %{"hostname" => "alpha"}})

    assert "alpha" in logs(results)
  end

  test "side effects run once, on the false->true transition only" do
    {dispatcher, _registry} =
      runtime("""
      condition networkchanged {
        when IP_CHANGED {
          log "once"
        }
      }
      """)

    assert logs(Dispatcher.dispatch(dispatcher, "IP_CHANGED")) == ["once"]
    assert logs(Dispatcher.dispatch(dispatcher, "IP_CHANGED")) == []
  end

  test "the body runs before the rules woken by CONDITION_<name>" do
    {dispatcher, _registry} =
      runtime("""
      condition ready {
        when IP_CHANGED {
          log "body"
        }
      }

      rule listener {
        when CONDITION_ready {
          log "listener"
        }
      }
      """)

    # The condition server emits its side effects before it announces the
    # transition, and the dispatcher drains both in arrival order. Reversing
    # them would run the reaction before the thing reacted to.
    assert logs(Dispatcher.dispatch(dispatcher, "IP_CHANGED")) == ["body", "listener"]
  end

  # --- The boundary constraint ---

  test "an emit from a condition body does not reach a rule outside the event's context" do
    {dispatcher, _registry} =
      runtime("""
      condition networkchanged {
        when IP_CHANGED {
          emit [EVENT::changed] as :NET_CHANGED
        }
      }

      rule scoped-listener {
        context "infra.networking" {
          when NET_CHANGED {
            log "scoped listener"
          }
        }
      }

      rule open-listener {
        when NET_CHANGED {
          log "open listener"
        }
      }
      """)

    # No context on the event: the scoped listener must stay closed even
    # though the emit originated inside the runtime rather than outside it.
    results = Dispatcher.dispatch(dispatcher, "IP_CHANGED")
    assert "open listener" in logs(results)
    refute "scoped listener" in logs(results)
  end

  test "an emit from a condition body reaches a scoped rule when the context matches" do
    {dispatcher, _registry} =
      runtime("""
      condition networkchanged {
        when IP_CHANGED {
          emit [EVENT::changed] as :NET_CHANGED
        }
      }

      rule scoped-listener {
        context "infra.networking" {
          when NET_CHANGED {
            log "scoped listener"
          }
        }
      }
      """)

    results =
      Dispatcher.dispatch(dispatcher, "IP_CHANGED", %{context_path: "infra.networking.dns"})

    assert "scoped listener" in logs(results)
  end

  test "a demand from a condition body cannot reach a context-scoped capability" do
    {:ok, ast} =
      Anemos.Parser.parse("""
      condition networkchanged {
        when IP_CHANGED {
          demand ddns-key
        }
      }
      """)

    {:ok, compiled} = Anemos.Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(
        rules: compiled.rules,
        conditions: compiled.conditions,
        registry: registry,
        capabilities: [
          %Anemos.CompiledCapability{
            name: "ddns-key",
            context: "infra.networking",
            handler: fn _ -> {:ok, [%{type: :emit, value: "SECRET"}]} end
          }
        ]
      )

    results = Dispatcher.dispatch(dispatcher, "IP_CHANGED")

    refute Enum.any?(results, &match?({:ok, %{type: :emit, value: "SECRET"}}, &1))

    assert Enum.any?(results, fn
             {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/capability_context_denied"}} ->
               true

             _ ->
               false
           end),
           "expected the demand to be refused, got: #{inspect(results)}"
  end

  # --- The recursion constraint ---

  test "a cycle entered from a condition body hits the depth ceiling and returns" do
    {dispatcher, _registry} =
      runtime("""
      condition kickoff {
        when START {
          emit [EVENT::go] as :PING
        }
      }

      rule ping {
        when PING {
          emit [EVENT::p] as :PONG
        }
      }

      rule pong {
        when PONG {
          emit [EVENT::q] as :PING
        }
      }
      """)

    results = Dispatcher.dispatch(dispatcher, "START")

    assert Enum.any?(results, fn
             {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/event_recursion_limit"}} ->
               true

             _ ->
               false
           end),
           "expected an event_recursion_limit error from a condition-entered cycle"

    # And the dispatcher is still serving.
    assert Process.alive?(dispatcher)
    assert Dispatcher.dispatch(dispatcher, "UNRELATED") == []
  end
end

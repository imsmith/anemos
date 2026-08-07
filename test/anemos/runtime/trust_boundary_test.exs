defmodule Anemos.Runtime.TrustBoundaryTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A-06, A-07, A-16, A-39.

  Under the 2026-08-06 multi-tenant decision `context` is a security
  boundary, so every test here asserts a *closed* door: an omitted event
  context must not open a scoped rule, a shared string prefix must not be
  mistaken for a shared context, and `nextrule` must not be a way around
  either. The state-threading assertions live here too because A-16 and
  A-39 are the same clause.
  """

  alias Anemos.Compiler
  alias Anemos.Parser
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  defp dispatcher_for(source, opts \\ []) do
    {:ok, ast} = Parser.parse(source)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(
        [rules: compiled.rules, capabilities: compiled.capabilities, registry: registry] ++ opts
      )

    dispatcher
  end

  defp logs(results) do
    for {:ok, %{type: :log, value: v}} <- results, do: v
  end

  # --- A-06: context isolation must fail closed ---

  describe "A-06 context isolation" do
    test "a scoped rule does not fire on an event that supplies no context" do
      dispatcher =
        dispatcher_for("""
        rule scoped {
          context "garage.motion" {
            when SENSOR_MOTION_DETECTED {
              log "motion in garage"
            }
          }
        }
        """)

      # Anemos.Runtime.dispatch/2 omits the context by default. Before the
      # fix this matched every scoped rule in the runtime.
      assert Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED") == []
      assert Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{}) == []
      assert Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{context_path: nil}) == []
    end

    test "a sibling context sharing a string prefix does not match" do
      dispatcher =
        dispatcher_for("""
        rule scoped {
          context "garage" {
            when SENSOR_MOTION_DETECTED {
              log "motion in garage"
            }
          }
        }
        """)

      assert Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{
               context_path: "garageband.amp"
             }) == []

      assert Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{context_path: "garagex"}) ==
               []

      # The boundary still admits the context itself and its descendants.
      assert logs(
               Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{context_path: "garage"})
             ) ==
               ["motion in garage"]

      assert logs(
               Dispatcher.dispatch(dispatcher, "SENSOR_MOTION_DETECTED", %{
                 context_path: "garage.door"
               })
             ) ==
               ["motion in garage"]
    end

    test "an unscoped rule still fires for any event, with or without context" do
      dispatcher =
        dispatcher_for("""
        rule global {
          when GLOBAL_EVENT {
            log "global"
          }
        }
        """)

      assert logs(Dispatcher.dispatch(dispatcher, "GLOBAL_EVENT")) == ["global"]

      assert logs(Dispatcher.dispatch(dispatcher, "GLOBAL_EVENT", %{context_path: "any.path"})) ==
               ["global"]
    end
  end

  # --- A-39: nextrule must not be a third route past the boundary ---

  describe "A-39 nextrule routing" do
    test "nextrule does not fire a scoped rule from an event with no context" do
      dispatcher =
        dispatcher_for("""
        rule opener {
          when EV {
            log "opener"
            nextrule privileged
          }
        }

        rule privileged {
          context "infra.networking" {
            when NEVER_SENT {
              log "privileged"
            }
          }
        }
        """)

      results = Dispatcher.dispatch(dispatcher, "EV")
      assert "opener" in logs(results)
      refute "privileged" in logs(results)
    end

    test "nextrule does not fire a scoped rule from a sibling-prefix context" do
      dispatcher =
        dispatcher_for("""
        rule opener {
          when EV {
            nextrule privileged
          }
        }

        rule privileged {
          context "garage" {
            when NEVER_SENT {
              log "privileged"
            }
          }
        }
        """)

      refute "privileged" in logs(
               Dispatcher.dispatch(dispatcher, "EV", %{context_path: "garageband"})
             )

      assert "privileged" in logs(
               Dispatcher.dispatch(dispatcher, "EV", %{context_path: "garage.door"})
             )
    end

    test "nextrule into a dwell-gated rule arms the timer instead of firing immediately" do
      dispatcher =
        dispatcher_for("""
        rule opener {
          when EV {
            nextrule dweller
          }
        }

        rule dweller {
          when SIGNAL for 10s {
            log "dwelled"
          }
        }
        """)

      results = Dispatcher.dispatch(dispatcher, "EV")
      refute "dwelled" in logs(results)
    end
  end

  # --- A-16: nextrule/nextevent must not discard state ---

  describe "A-16 state threading" do
    test "set bindings written by a rule reached via nextrule survive" do
      dispatcher =
        dispatcher_for("""
        rule marker {
          when TICK {
            log $n
            set n = "seen"
          }
        }

        rule driver {
          when DRIVE {
            nextrule marker
          }
        }
        """)

      # Baseline: a direct firing persists its own `set`.
      assert logs(Dispatcher.dispatch(dispatcher, "TICK")) == [nil]
      assert logs(Dispatcher.dispatch(dispatcher, "TICK")) == ["seen"]
    end

    test "a set written on the nextrule path is not thrown away" do
      dispatcher =
        dispatcher_for("""
        rule marker {
          when TICK {
            log $n
            set n = "seen"
          }
        }

        rule driver {
          when DRIVE {
            nextrule marker
          }
        }
        """)

      # Only the nextrule path ever runs `marker`. Before the fix its
      # `set` evaporated and the next read was still nil.
      assert logs(Dispatcher.dispatch(dispatcher, "DRIVE")) == [nil]
      assert logs(Dispatcher.dispatch(dispatcher, "TICK")) == ["seen"]
    end

    test "a set written on the nextevent path is not thrown away" do
      dispatcher =
        dispatcher_for("""
        rule marker {
          when TICK {
            log $n
            set n = "seen"
          }
        }

        rule driver {
          when DRIVE {
            nextevent TICK
          }
        }
        """)

      assert logs(Dispatcher.dispatch(dispatcher, "DRIVE")) == [nil]
      assert logs(Dispatcher.dispatch(dispatcher, "TICK")) == ["seen"]
    end
  end

  # --- A-07: capability context scoping must be enforced ---

  describe "A-07 capability context scoping" do
    defp with_capability(rule_source, cap_context) do
      {:ok, ast} = Parser.parse(rule_source)
      {:ok, compiled} = Compiler.compile(ast)
      {:ok, registry} = ModuleRegistry.start_link([])

      {:ok, dispatcher} =
        Anemos.Runtime.Standalone.start_link(
          rules: compiled.rules,
          registry: registry,
          capabilities: [
            %Anemos.CompiledCapability{
              name: "ddns-key",
              context: cap_context,
              handler: fn _ctx -> {:ok, [%{type: :emit, value: "SECRET"}]} end
            }
          ]
        )

      dispatcher
    end

    defp secret_leaked?(results) do
      Enum.any?(results, &match?({:ok, %{type: :emit, value: "SECRET"}}, &1))
    end

    @unscoped_demander """
    rule thief {
      when EV {
        demand ddns-key
      }
    }
    """

    @scoped_demander """
    rule inside {
      context "infra.networking.dns" {
        when EV {
          demand ddns-key
        }
      }
    }
    """

    @sibling_demander """
    rule sibling {
      context "infra.networkingx" {
        when EV {
          demand ddns-key
        }
      }
    }
    """

    test "a rule with no context cannot demand a context-scoped capability" do
      dispatcher = with_capability(@unscoped_demander, "infra.networking")
      results = Dispatcher.dispatch(dispatcher, "EV")

      refute secret_leaked?(results)

      assert Enum.any?(results, fn
               {:error,
                %Comn.Errors.ErrorStruct{code: "anemos.runtime/capability_context_denied"}} ->
                 true

               _ ->
                 false
             end),
             "expected a capability_context_denied error, got: #{inspect(results)}"
    end

    test "a rule inside the capability's context may demand it" do
      dispatcher = with_capability(@scoped_demander, "infra.networking")
      results = Dispatcher.dispatch(dispatcher, "EV", %{context_path: "infra.networking.dns"})
      assert secret_leaked?(results)
    end

    test "a sibling context sharing a string prefix cannot demand it" do
      dispatcher = with_capability(@sibling_demander, "infra.networking")
      results = Dispatcher.dispatch(dispatcher, "EV", %{context_path: "infra.networkingx"})
      refute secret_leaked?(results)
    end

    test "an unscoped capability is demandable from anywhere" do
      dispatcher = with_capability(@unscoped_demander, nil)
      assert secret_leaked?(Dispatcher.dispatch(dispatcher, "EV"))
    end

    test "a context denial is fatal under every demand flag" do
      for flag <- [:requisite, :required, :optional, :sufficient] do
        {:ok, pid} =
          Anemos.Runtime.CapabilityServer.start_link(
            name_str: "k",
            context: "infra.networking",
            handler: fn _ -> {:ok, [%{type: :emit, value: "SECRET"}]} end
          )

        assert {:error,
                %Comn.Errors.ErrorStruct{code: "anemos.runtime/capability_context_denied"}} =
                 Anemos.Runtime.Demand.evaluate(
                   [%{capability: "k", flag: flag}],
                   %{"k" => pid},
                   %{_rule_source: {"thief", nil}}
                 ),
               "flag #{flag} let a context-denied capability through"
      end
    end
  end

  # --- The shared predicate ---

  describe "Anemos.Runtime.ContextScope.within?/2" do
    alias Anemos.Runtime.ContextScope

    test "an unscoped outer admits everything" do
      assert ContextScope.within?("anything", nil)
      assert ContextScope.within?(nil, nil)
      assert ContextScope.within?(nil, "")
    end

    test "a scoped outer denies an absent inner" do
      refute ContextScope.within?(nil, "garage")
      refute ContextScope.within?("", "garage")
    end

    test "equality and descent match, prefix alone does not" do
      assert ContextScope.within?("garage", "garage")
      assert ContextScope.within?("garage.door", "garage")
      assert ContextScope.within?("garage.door.left", "garage")
      refute ContextScope.within?("garageband", "garage")
      refute ContextScope.within?("garageband.amp", "garage")
      refute ContextScope.within?("gara", "garage")
    end
  end
end

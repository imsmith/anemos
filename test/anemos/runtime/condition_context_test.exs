defmodule Anemos.Runtime.ConditionContextTest do
  use ExUnit.Case, async: true

  @moduledoc """
  A-54. `CompiledCondition.context` is declared by the struct and consumed by
  the dispatcher's `condition_contexts` map, but `compile_condition/1` never
  filled it. It was `nil` for every condition ever compiled, so a `context`
  block inside a condition body was parsed and then dropped.

  The visible consequence: a condition could never demand a context-scoped
  capability. It always presented `nil`, and `ContextScope.within?/2` denies
  `nil` against any declared scope. Fail-closed by accident, not by
  declaration — and the correct-by-declaration outcome is the one these tests
  pin down, in both directions.
  """

  alias Anemos.Runtime.{Dispatcher, ModuleRegistry}

  defp compiled_condition(source) do
    {:ok, ast} = Anemos.Parser.parse(source)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    [condition] = compiled.conditions
    condition
  end

  defp runtime(source, capability_context) do
    {:ok, ast} = Anemos.Parser.parse(source)
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
            context: capability_context,
            handler: fn _ -> {:ok, [%{type: :emit, value: "SECRET"}]} end
          }
        ]
      )

    dispatcher
  end

  defp scoped_condition(path) do
    """
    condition networkchanged {
      context "#{path}" {
        when IP_CHANGED {
          demand ddns-key
        }
      }
    }
    """
  end

  defp granted?(results),
    do: Enum.any?(results, &match?({:ok, %{type: :emit, value: "SECRET"}}, &1))

  defp denied?(results) do
    Enum.any?(results, fn
      {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/capability_context_denied"}} -> true
      _ -> false
    end)
  end

  # --- The compile-time gap ---

  test "a condition's declared context reaches the compiled struct" do
    condition = compiled_condition(scoped_condition("infra.networking"))

    assert condition.context == "infra.networking"
  end

  test "a condition with no context block compiles to a nil context" do
    condition =
      compiled_condition("""
      condition networkchanged {
        when IP_CHANGED {
          demand ddns-key
        }
      }
      """)

    assert condition.context == nil
  end

  test "the context block's body is still traversed for subscriptions" do
    condition = compiled_condition(scoped_condition("infra.networking"))

    assert "IP_CHANGED" in condition.subscriptions
  end

  # --- The runtime consequence, in both directions ---

  test "a condition inside a matching context may demand a scoped capability" do
    dispatcher = runtime(scoped_condition("infra.networking"), "infra.networking")

    results = Dispatcher.dispatch(dispatcher, "IP_CHANGED")

    assert granted?(results), "expected the demand to be granted, got: #{inspect(results)}"
    refute denied?(results)
  end

  test "a condition nested below the capability's scope may still demand it" do
    dispatcher = runtime(scoped_condition("infra.networking.dns"), "infra.networking")

    results = Dispatcher.dispatch(dispatcher, "IP_CHANGED")

    assert granted?(results), "expected the demand to be granted, got: #{inspect(results)}"
  end

  test "a condition in a sibling context is denied" do
    dispatcher = runtime(scoped_condition("infra.storage"), "infra.networking")

    results = Dispatcher.dispatch(dispatcher, "IP_CHANGED")

    refute granted?(results)
    assert denied?(results), "expected the demand to be refused, got: #{inspect(results)}"
  end

  test "a sibling-prefix context is denied, not treated as a prefix match" do
    dispatcher = runtime(scoped_condition("infra.networking-evil"), "infra.networking")

    results = Dispatcher.dispatch(dispatcher, "IP_CHANGED")

    refute granted?(results)
    assert denied?(results), "expected the demand to be refused, got: #{inspect(results)}"
  end
end

defmodule Anemos.Runtime.Demand do
  @moduledoc """
  Evaluates a stack of demand operations against capability servers
  using PAM-style control flag semantics.

  Flags:
  - `:requisite` (default) — must succeed, fail immediately if not
  - `:required` — must succeed, but evaluate rest of stack before failing
  - `:optional` — continue whether it succeeds or fails
  - `:sufficient` — if succeeds, skip rest of stack
  """

  alias Anemos.Runtime.CapabilityServer

  @spec evaluate([map()], map(), map()) :: {:ok, list()} | {:error, term()}
  def evaluate(demands, capability_registry, context) do
    eval_stack(demands, capability_registry, context, [], nil)
  end

  defp eval_stack([], _registry, _context, results, nil) do
    {:ok, Enum.reverse(results) |> List.flatten()}
  end

  defp eval_stack([], _registry, _context, _results, deferred_error) do
    deferred_error
  end

  defp eval_stack([demand | rest], registry, context, results, deferred_error) do
    case Map.get(registry, demand.capability) do
      nil -> handle_missing(demand, rest, registry, context, results, deferred_error)
      pid ->
        case CapabilityServer.execute(pid, context) do
          {:ok, ops} -> handle_success(demand, ops, rest, registry, context, results, deferred_error)
          {:error, reason} -> handle_failure(demand, reason, rest, registry, context, results, deferred_error)
        end
    end
  end

  defp handle_missing(demand, rest, registry, context, results, deferred_error) do
    error = {:error, {:unknown_capability, demand.capability}}
    case demand.flag do
      :requisite -> error
      :required -> eval_stack(rest, registry, context, results, deferred_error || error)
      :optional -> eval_stack(rest, registry, context, results, deferred_error)
      :sufficient -> eval_stack(rest, registry, context, results, deferred_error)
    end
  end

  defp handle_success(demand, ops, rest, registry, context, results, deferred_error) do
    case demand.flag do
      :sufficient -> {:ok, Enum.reverse(results) ++ List.wrap(ops)}
      _ -> eval_stack(rest, registry, context, List.wrap(ops) ++ results, deferred_error)
    end
  end

  defp handle_failure(demand, reason, rest, registry, context, results, deferred_error) do
    error = {:error, {:demand_failed, demand.capability, reason}}
    case demand.flag do
      :requisite -> error
      :required -> eval_stack(rest, registry, context, results, deferred_error || error)
      :optional -> eval_stack(rest, registry, context, results, deferred_error)
      :sufficient -> eval_stack(rest, registry, context, results, deferred_error)
    end
  end
end

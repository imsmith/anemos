defmodule Anemos.Runtime.Demand do
  @moduledoc """
  Evaluates a stack of demand operations against capability servers
  using PAM-style control flag semantics.

  Flags:
  - `:requisite` (default) — must succeed, fail immediately if not
  - `:required` — must succeed, but evaluate rest of stack before failing
  - `:optional` — continue whether it succeeds or fails
  - `:sufficient` — if succeeds, skip rest of stack

  ## Missing capabilities are not failures

  The flags above govern how *failure* is handled. A capability that is not
  present in the registry has not failed — it was never loaded, which is a
  configuration error in the policy text (typically a typo in the capability
  name). Such a demand is fatal under every flag, including `:optional` and
  `:sufficient`.

  Were it otherwise, a stack composed entirely of `:optional` demands naming
  capabilities that do not exist would return `{:ok, []}` — a gate that reads
  as an authorization check while authorizing nothing.
  """

  alias Anemos.Runtime.CapabilityServer

  @doc """
  Evaluates a demand stack against capability servers using PAM-style control flags.

  Each demand in the list must have `:capability` (name) and `:flag` (one of
  `:requisite`, `:required`, `:optional`, `:sufficient`).

  Returns `{:ok, operations}` or `{:error, reason}`.

  ## Examples

      iex> {:ok, pid} = Anemos.Runtime.CapabilityServer.start_link(name_str: "k", context: "t", handler: fn _ -> {:ok, [%{type: :log, value: "ok"}]} end)
      iex> {:ok, ops} = Anemos.Runtime.Demand.evaluate([%{capability: "k", flag: :requisite}], %{"k" => pid}, %{})
      iex> [%{type: :log, value: "ok"}] = ops
      [%{type: :log, value: "ok"}]

  """
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
      nil -> handle_missing(demand)
      pid ->
        case CapabilityServer.execute(pid, context) do
          {:ok, ops} -> handle_success(demand, ops, rest, registry, context, results, deferred_error)
          {:error, reason} -> handle_failure(demand, reason, rest, registry, context, results, deferred_error)
        end
    end
  end

  # Fatal regardless of flag — see the moduledoc. Note the absence of any
  # `rest` argument: there is no continuation from here.
  defp handle_missing(demand) do
    {:error,
     Comn.Errors.Registry.error!("anemos.runtime/unknown_capability",
       message: "Capability #{demand.capability} not found in registry"
     )}
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

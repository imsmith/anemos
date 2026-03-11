defmodule Anemos.Runtime.Dispatcher do
  @moduledoc """
  GenServer holding compiled rules indexed by subscription.

  Dispatches events to matching rules, executes resulting operations
  via the ModuleRegistry.
  """

  use GenServer

  alias Anemos.Runtime.ModuleRegistry

  # --- Client API ---

  def start_link(opts) do
    rules = Keyword.fetch!(opts, :rules)
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, rules, name: name)
  end

  @spec dispatch(pid() | atom(), String.t(), map(), keyword()) :: list()
  def dispatch(dispatcher, event_name, context \\ %{}, opts \\ []) do
    GenServer.call(dispatcher, {:dispatch, event_name, context, opts})
  end

  # --- Server callbacks ---

  @impl true
  def init(rules) do
    index = build_index(rules)
    {:ok, %{rules: rules, index: index}}
  end

  @impl true
  def handle_call({:dispatch, event_name, context, opts}, _from, state) do
    registry = Keyword.fetch!(opts, :registry)
    matching = Map.get(state.index, event_name, [])

    results =
      matching
      |> Enum.flat_map(fn rule ->
        {:ok, ops} = rule.handler.(event_name, context)
        Enum.map(ops, &execute_op(&1, context, registry))
      end)

    {:reply, results, state}
  end

  # --- Private ---

  defp build_index(rules) do
    Enum.reduce(rules, %{}, fn rule, acc ->
      Enum.reduce(rule.subscriptions, acc, fn event, inner_acc ->
        Map.update(inner_acc, event, [rule], &(&1 ++ [rule]))
      end)
    end)
  end

  defp execute_op(%{type: :command, module: mod_name, verb: verb, args: args}, context, registry) do
    case ModuleRegistry.lookup(registry, mod_name) do
      {:ok, mod} -> mod.handle_verb(verb, args, context)
      :error -> {:error, {:unknown_module, mod_name}}
    end
  end

  defp execute_op(%{type: :log} = op, _context, _registry) do
    {:ok, op}
  end

  defp execute_op(%{type: :emit} = op, _context, _registry) do
    {:ok, op}
  end

  defp execute_op(%{type: :demand} = op, _context, _registry) do
    {:ok, op}
  end

  defp execute_op(%{type: :set} = op, _context, _registry) do
    {:ok, op}
  end
end

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
    registry = Keyword.fetch!(opts, :registry)
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, {rules, registry}, name: name)
  end

  @spec dispatch(pid() | atom(), String.t(), map()) :: list()
  def dispatch(dispatcher, event_name, context \\ %{}) do
    GenServer.call(dispatcher, {:dispatch, event_name, context})
  end

  # --- Server callbacks ---

  @impl true
  def init({rules, registry}) do
    index = build_index(rules)
    {:ok, %{rules: rules, index: index, registry: registry}}
  end

  @impl true
  def handle_call({:dispatch, event_name, context}, _from, state) do
    matching = Map.get(state.index, event_name, [])

    results =
      matching
      |> Enum.flat_map(fn rule ->
        case safe_handle(rule, event_name, context) do
          {:ok, ops} ->
            Enum.map(ops, &execute_op(&1, context, state.registry))

          {:error, reason} ->
            [{:error, {:handler_crash, rule.name, reason}}]
        end
      end)

    {:reply, results, state}
  end

  # --- Private ---

  defp safe_handle(rule, event_name, context) do
    rule.handler.(event_name, context)
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp build_index(rules) do
    Enum.reduce(rules, %{}, fn rule, acc ->
      Enum.reduce(rule.subscriptions, acc, fn event, inner_acc ->
        Map.update(inner_acc, event, [rule], &[rule | &1])
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

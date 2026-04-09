defmodule Anemos.Runtime.Dispatcher do
  @moduledoc """
  GenServer holding compiled rules indexed by subscription.

  Dispatches events to matching rules, executes resulting operations
  via the ModuleRegistry. Also manages ConditionServer instances and
  routes synthetic CONDITION_<name> events when conditions transition.
  """

  use GenServer

  alias Anemos.Runtime.{CapabilityServer, ConditionServer, ModuleRegistry}

  # --- Client API ---

  @doc """
  Starts a dispatcher.

  ## Options

    * `:rules` — list of `%Anemos.CompiledRule{}` structs (required)
    * `:registry` — pid of a `ModuleRegistry` (required)
    * `:conditions` — list of `%Anemos.CompiledCondition{}` structs (optional)
    * `:capabilities` — list of `%Anemos.CompiledCapability{}` structs (optional)
    * `:name` — process registration name (optional)
  """
  def start_link(opts) do
    rules = Keyword.fetch!(opts, :rules)
    registry = Keyword.fetch!(opts, :registry)
    conditions = Keyword.get(opts, :conditions, [])
    capabilities = Keyword.get(opts, :capabilities, [])
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, {rules, registry, conditions, capabilities}, name: name)
  end

  @doc """
  Dispatches an event to all matching rules and conditions.

  Returns a list of `{:ok, operation}` or `{:error, reason}` tuples.
  """
  @spec dispatch(pid() | atom(), String.t(), map()) :: list()
  def dispatch(dispatcher, event_name, context \\ %{}) do
    GenServer.call(dispatcher, {:dispatch, event_name, context})
  end

  @doc """
  Returns the current boolean state of a named condition, or `nil` if not found.
  """
  @spec condition_state(pid() | atom(), String.t()) :: boolean() | nil
  def condition_state(dispatcher, condition_name) do
    GenServer.call(dispatcher, {:condition_state, condition_name})
  end

  # --- Server callbacks ---

  @impl true
  def init({rules, registry, compiled_conditions, compiled_capabilities}) do
    index = build_index(rules)
    dispatcher_pid = self()

    condition_servers =
      Map.new(compiled_conditions, fn cond_spec ->
        {:ok, pid} =
          ConditionServer.start_link(
            name_str: cond_spec.name,
            subscriptions: cond_spec.subscriptions,
            evaluator: cond_spec.evaluator,
            side_effects: cond_spec.side_effects,
            on_transition: fn name ->
              send(dispatcher_pid, {:condition_transition, name})
            end
          )

        {cond_spec.name, %{pid: pid, subscriptions: cond_spec.subscriptions}}
      end)

    capability_servers =
      Map.new(compiled_capabilities, fn cap ->
        {:ok, pid} =
          CapabilityServer.start_link(
            name_str: cap.name,
            context: cap.context || "",
            handler: cap.handler
          )

        {cap.name, pid}
      end)

    {:ok,
     %{
       rules: rules,
       index: index,
       registry: registry,
       condition_servers: condition_servers,
       capability_servers: capability_servers
     }}
  end

  @impl true
  def handle_call({:dispatch, event_name, context}, _from, state) do
    # Route event to all condition servers (async cast)
    Enum.each(state.condition_servers, fn {_name, %{pid: pid}} ->
      ConditionServer.handle_event(pid, event_name, context)
    end)

    # Synchronize: call get_state on each condition server to ensure all casts
    # have been processed before we drain the transition messages from our mailbox.
    Enum.each(state.condition_servers, fn {_name, %{pid: pid}} ->
      ConditionServer.get_state(pid)
    end)

    # Collect any condition transition messages now in our mailbox
    synthetic_events = collect_transitions()

    # Dispatch original event to matching rules
    results = dispatch_to_rules(event_name, context, state)

    # Dispatch synthetic CONDITION_<name> events to matching rules
    synthetic_results =
      Enum.flat_map(synthetic_events, fn cond_name ->
        dispatch_to_rules("CONDITION_#{cond_name}", context, state)
      end)

    {:reply, results ++ synthetic_results, state}
  end

  @impl true
  def handle_call({:condition_state, name}, _from, state) do
    case Map.get(state.condition_servers, name) do
      %{pid: pid} -> {:reply, ConditionServer.get_state(pid), state}
      nil -> {:reply, nil, state}
    end
  end

  @impl true
  def handle_info({:condition_transition, _name}, state) do
    # Transition messages are drained synchronously during dispatch;
    # any that arrive outside a dispatch cycle are silently ignored.
    {:noreply, state}
  end

  # --- Private ---

  defp dispatch_to_rules(event_name, context, state) do
    matching = Map.get(state.index, event_name, [])
    event_context = Map.get(context, :context_path)

    matching
    |> Enum.filter(&context_matches?(&1, event_context))
    |> Enum.flat_map(fn rule ->
      case safe_handle(rule, event_name, context) do
        {:ok, ops} ->
          Enum.flat_map(ops, fn op ->
            List.wrap(execute_op(op, context, state.registry, state.capability_servers))
          end)

        {:error, reason} ->
          [{:error, {:handler_crash, rule.name, reason}}]
      end
    end)
  end

  defp context_matches?(_rule, nil), do: true

  defp context_matches?(rule, event_context) do
    case get_in(rule, [Access.key(:meta), :context_path]) do
      nil -> true
      rule_context -> String.starts_with?(event_context, rule_context)
    end
  end

  defp collect_transitions do
    collect_transitions([])
  end

  defp collect_transitions(acc) do
    receive do
      {:condition_transition, name} -> collect_transitions([name | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Crash boundary for compiled rule handler closures. Catches exception types
  # that can arise from evaluated user-supplied .rule code. Unexpected exception
  # types are intentionally left to crash and restart via the supervisor.
  defp safe_handle(rule, event_name, context) do
    rule.handler.(event_name, context)
  rescue
    e in RuntimeError -> {:error, Exception.message(e)}
    e in ArgumentError -> {:error, Exception.message(e)}
    e in FunctionClauseError -> {:error, Exception.message(e)}
    e in MatchError -> {:error, Exception.message(e)}
    e in BadMapError -> {:error, Exception.message(e)}
    e in KeyError -> {:error, Exception.message(e)}
    e in UndefinedFunctionError -> {:error, Exception.message(e)}
    e in ArithmeticError -> {:error, Exception.message(e)}
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

  defp execute_op(%{type: :command, module: mod_name, verb: verb, args: args}, context, registry, _capability_servers) do
    case ModuleRegistry.lookup(registry, mod_name) do
      {:ok, mod} -> mod.handle_verb(verb, args, context)
      :error -> {:error, {:unknown_module, mod_name}}
    end
  end

  defp execute_op(%{type: :log} = op, _context, _registry, _capability_servers) do
    {:ok, op}
  end

  defp execute_op(%{type: :emit} = op, _context, _registry, _capability_servers) do
    {:ok, op}
  end

  defp execute_op(%{type: :demand, capability: cap_name} = op, context, _registry, capability_servers) do
    demands = [%{capability: cap_name, flag: Map.get(op, :flag, :requisite)}]

    case Anemos.Runtime.Demand.evaluate(demands, capability_servers, context) do
      {:ok, ops} -> Enum.map(ops, fn result_op -> {:ok, result_op} end)
      {:error, _} = err -> [err]
    end
  end

  defp execute_op(%{type: :set} = op, _context, _registry, _capability_servers) do
    {:ok, op}
  end
end

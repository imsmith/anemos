defmodule Anemos.Runtime.Dispatcher do
  @moduledoc """
  GenServer holding compiled rules indexed by subscription.

  Dispatches events to matching rules, executes resulting operations
  via the ModuleRegistry. Also manages ConditionServer instances and
  routes synthetic `CONDITION_<name>` events when conditions transition.

  Handled operation types: `:command`, `:log`, `:emit`, `:demand`,
  `:assert_triple`, `:triple_query`, `:nextevent`, `:nextrule`.
  """

  use GenServer
  require Logger

  @behaviour Comn

  alias Anemos.Runtime.{CapabilityServer, ConditionServer, DataStore, ModuleRegistry, TripleStore}

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
    channel_connector = Keyword.get(opts, :channel_connector, Anemos.Channel.Logger)
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, {rules, registry, conditions, capabilities, channel_connector}, name: name)
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
  Loads compiled rules, conditions, and capabilities into a running dispatcher.

  New declarations are added to the existing set — nothing is replaced.
  """
  @spec load(pid() | atom(), Anemos.CompilationResult.t()) :: :ok
  def load(dispatcher, compiled) do
    GenServer.call(dispatcher, {:load, compiled})
  end

  @doc """
  Returns the current boolean state of a named condition, or `nil` if not found.
  """
  @spec condition_state(pid() | atom(), String.t()) :: boolean() | nil
  def condition_state(dispatcher, condition_name) do
    GenServer.call(dispatcher, {:condition_state, condition_name})
  end

  @doc """
  Returns true if `value` is a member of the named data block dataset.
  """
  @spec data_member?(pid() | atom(), String.t(), term()) :: boolean()
  def data_member?(dispatcher, name, value) do
    GenServer.call(dispatcher, {:data_member?, name, value})
  end

  # --- Server callbacks ---

  @impl true
  def init({rules, registry, compiled_conditions, compiled_capabilities, channel_connector}) do
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
            side_effect_handler: cond_spec.side_effect_handler,
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

    {:ok, triple_store} = TripleStore.start_link()
    {:ok, data_store} = DataStore.start_link()

    {:ok,
     %{
       rules: rules,
       index: index,
       registry: registry,
       condition_servers: condition_servers,
       capability_servers: capability_servers,
       triple_store: triple_store,
       data_store: data_store,
       channel_connector: channel_connector,
       rule_bindings: %{}
     }}
  end

  @impl true
  def handle_call({:dispatch, event_name, context}, _from, state) do
    comn_ctx = build_comn_context(event_name, context)

    {results, state} =
      Comn.Contexts.with_context(comn_ctx, fn ->
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
        {results, state} = dispatch_to_rules(event_name, context, state)

        # Dispatch synthetic CONDITION_<name> events to matching rules
        {synthetic_results, state} =
          Enum.reduce(synthetic_events, {[], state}, fn cond_name, {acc, st} ->
            {res, st} = dispatch_to_rules("CONDITION_#{cond_name}", context, st)
            {acc ++ res, st}
          end)

        {results ++ synthetic_results, state}
      end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:load, compiled}, _from, state) do
    dispatcher_pid = self()

    # Start new condition servers
    new_condition_servers =
      Map.new(compiled.conditions, fn cond_spec ->
        {:ok, pid} =
          ConditionServer.start_link(
            name_str: cond_spec.name,
            subscriptions: cond_spec.subscriptions,
            evaluator: cond_spec.evaluator,
            side_effects: cond_spec.side_effects,
            side_effect_handler: cond_spec.side_effect_handler,
            on_transition: fn name ->
              send(dispatcher_pid, {:condition_transition, name})
            end
          )

        {cond_spec.name, %{pid: pid, subscriptions: cond_spec.subscriptions}}
      end)

    # Start new capability servers
    new_capability_servers =
      Map.new(compiled.capabilities, fn cap ->
        {:ok, pid} =
          CapabilityServer.start_link(
            name_str: cap.name,
            context: cap.context || "",
            handler: cap.handler
          )

        {cap.name, pid}
      end)

    # Register data blocks
    Enum.each(Map.get(compiled, :data_blocks, []), fn data ->
      if data.dataset do
        DataStore.register(state.data_store, data.name, data.scope || :global, data.dataset,
          source: data.source)
      end
    end)

    # Merge into existing state
    merged_rules = state.rules ++ compiled.rules
    merged_conditions = Map.merge(state.condition_servers, new_condition_servers)
    merged_capabilities = Map.merge(state.capability_servers, new_capability_servers)

    new_state = %{
      state
      | rules: merged_rules,
        index: build_index(merged_rules),
        condition_servers: merged_conditions,
        capability_servers: merged_capabilities
    }

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:condition_state, name}, _from, state) do
    case Map.get(state.condition_servers, name) do
      %{pid: pid} -> {:reply, ConditionServer.get_state(pid), state}
      nil -> {:reply, nil, state}
    end
  end

  @impl true
  def handle_call({:data_member?, name, value}, _from, state) do
    result = DataStore.member?(state.data_store, name, value)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_connector, connector}, _from, state) do
    {:reply, :ok, %{state | channel_connector: connector}}
  end

  @impl true
  def handle_info({:condition_transition, _name}, state) do
    # Transition messages are drained synchronously during dispatch;
    # any that arrive outside a dispatch cycle are silently ignored.
    {:noreply, state}
  end

  defp build_comn_context(event_name, context) do
    fields = [
      request_id: Map.get(context, :request_id, generate_request_id()),
      parent_event_id: event_name,
      correlation_id: Map.get(context, :correlation_id),
      trace_id: Map.get(context, :trace_id),
      actor: Map.get(context, :actor),
      metadata: %{context_path: Map.get(context, :context_path)}
    ]

    Comn.Contexts.ContextStruct.new(fields)
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end

  # --- Comn callbacks ---

  @impl Comn
  def look, do: "Dispatcher — routes events to matching rules and executes operations"

  @impl Comn
  def recon do
    %{
      type: :implementation,
      operations: [:command, :log, :emit, :demand, :assert_triple, :triple_query, :nextevent, :nextrule]
    }
  end

  @impl Comn
  def choices do
    %{actions: ["dispatch", "load", "condition_state"]}
  end

  @impl Comn
  def act(%{action: :dispatch, pid: pid, event: event, context: ctx}), do: {:ok, dispatch(pid, event, ctx)}
  def act(%{action: :dispatch, pid: pid, event: event}), do: {:ok, dispatch(pid, event)}
  def act(_input), do: {:error, :unknown_action}

  # --- Private ---

  defp dispatch_to_rules(event_name, context, state) do
    matching = Map.get(state.index, event_name, [])
    event_context = Map.get(context, :context_path)

    matching
    |> Enum.filter(&context_matches?(&1, event_context))
    |> Enum.reduce({[], state}, fn rule, {results_acc, st} ->
      persistent = Map.get(st.rule_bindings, rule.name, %{})

      # Pass DataStore pid through context so compiled closures can resolve memberof()
      enriched_context = Map.put(context, :data_store, st.data_store)

      case safe_handle(rule, event_name, enriched_context, persistent) do
        {:ok, ops, new_persistent} ->
          new_st = put_in(st.rule_bindings[rule.name], new_persistent)
          rule_context = Map.get(rule, :meta, %{}) |> Map.get(:context_path)
          exec_context = Map.put(context, :_rule_source, {rule.name, rule_context})

          all_results =
            Enum.flat_map(ops, fn op ->
              List.wrap(execute_op(op, exec_context, new_st))
            end)

          {normal_results, emit_events} =
            Enum.split_with(all_results, fn
              {:emit_event, _, _} -> false
              _ -> true
            end)

          {emit_results, new_st} =
            Enum.reduce(emit_events, {[], new_st}, fn {:emit_event, label, op}, {acc, s} ->
              {sub_results, s} = dispatch_to_rules(label, context, s)
              {acc ++ [{:ok, op} | sub_results], s}
            end)

          {results_acc ++ normal_results ++ emit_results, new_st}

        {:error, reason} ->
          err = Comn.Errors.Registry.error!("anemos.runtime/handler_crash",
            message: "Rule #{rule.name} raised: #{inspect(reason)}")
          {results_acc ++ [{:error, err}], st}
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
  defp safe_handle(rule, event_name, context, persistent_bindings) do
    rule.handler.(event_name, context, persistent_bindings)
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

  defp execute_op(%{type: :command, module: mod_name, verb: verb, args: args}, context, state) do
    case ModuleRegistry.lookup(state.registry, mod_name) do
      {:ok, mod} -> mod.handle_verb(verb, args, context)
      :error ->
        {:error, Comn.Errors.Registry.error!("anemos.runtime/unknown_module",
          message: "Module #{mod_name} not found in registry")}
    end
  end

  defp execute_op(%{type: :log, value: value} = op, _context, _state) do
    Logger.info("[anemos] #{value}")
    {:ok, op}
  end

  defp execute_op(%{type: :emit} = op, context, state) do
    # Publish to channel if destination is present
    if match?({:channel, _}, op[:destination]) do
      {:channel, channel_path} = op.destination

      source =
        case context[:_rule_source] do
          {name, nil} -> name
          {name, ctx} -> "#{name}@#{ctx}"
          nil -> nil
        end

      envelope = %Anemos.Envelope{
        type: op[:emit_type],
        payload: op.value,
        source: source,
        label: op[:label],
        channel: channel_path,
        timestamp: DateTime.utc_now()
      }
      state.channel_connector.publish(channel_path, envelope)
    end

    # Re-dispatch label as event if present
    if is_binary(op[:label]) do
      {:emit_event, op.label, op}
    else
      {:ok, op}
    end
  end

  defp execute_op(%{type: :demand, capability: cap_name} = op, context, state) do
    demands = [%{capability: cap_name, flag: Map.get(op, :flag, :requisite)}]

    case Anemos.Runtime.Demand.evaluate(demands, state.capability_servers, context) do
      {:ok, ops} -> Enum.map(ops, fn result_op -> {:ok, result_op} end)
      {:error, _} = err -> [err]
    end
  end

  defp execute_op(%{type: :assert_triple, subject: s, predicate: p, object: o} = op, _context, state) do
    TripleStore.assert_triple(state.triple_store, s, p, o)
    {:ok, op}
  end

  defp execute_op(%{type: :triple_query} = op, _context, state) do
    s = triple_query_pattern(op.subject)
    p = triple_query_pattern(op.predicate)
    o = triple_query_pattern(op.object)
    results = TripleStore.match(state.triple_store, s, p, o)
    {:ok, %{type: :triple_result, query: op, results: results}}
  end

  defp execute_op(%{type: :nextevent, target: target}, context, state) do
    {results, _state} = dispatch_to_rules(target, context, state)
    results
  end

  defp execute_op(%{type: :nextrule, target: target}, context, state) do
    matching = Enum.filter(state.rules, fn rule -> rule.name == target end)

    Enum.flat_map(matching, fn rule ->
      persistent = Map.get(state.rule_bindings, rule.name, %{})
      case safe_handle(rule, "nextrule:#{target}", context, persistent) do
        {:ok, ops, _new_persistent} ->
          Enum.flat_map(ops, fn op -> List.wrap(execute_op(op, context, state)) end)
        {:error, reason} ->
          [{:error, {:handler_crash, rule.name, reason}}]
      end
    end)
  end

  # NOTE: Inline data blocks with :local scope are registered as :global because
  # rules don't run as separate processes — self() is the dispatcher pid, so
  # {:local, self()} would make all inline blocks share one scope. True per-rule
  # scoping requires either process-per-rule or a rule-name-based scope discriminator
  # threaded through both registration and lookup. For now, inline local data blocks
  # are promoted to global scope.
  defp execute_op(%{type: :register_data, data: data}, _context, state) do
    if data.dataset do
      DataStore.register(state.data_store, data.name, :global, data.dataset)
    end
    {:ok, %{type: :register_data, name: data.name}}
  end

  defp execute_op(%{type: :register_query, query: query}, _context, _state) do
    {:ok, %{type: :register_query, name: query.name}}
  end

  defp triple_query_pattern({:var, _} = var), do: var
  defp triple_query_pattern(literal), do: literal
end

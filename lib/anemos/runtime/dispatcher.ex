defmodule Anemos.Runtime.Dispatcher do
  @moduledoc """
  GenServer holding compiled rules indexed by subscription.

  Dispatches events to matching rules, executes resulting operations
  via the ModuleRegistry. Also routes synthetic `CONDITION_<name>` events
  when conditions transition.

  Handled operation types: `:command`, `:log`, `:emit`, `:demand`,
  `:assert_triple`, `:triple_query`, `:nextevent`, `:nextrule`.

  ## Owns no process lifecycles

  The dispatcher `start_link`s nothing. Condition servers, capability
  servers, the triple store, the data store and the subscribable registry
  all live under `Anemos.Runtime.StoreSupervisor`, and are resolved by
  child id at the head of every callback (`refresh_stores/1`). The
  dispatcher's own state is a *derived* view, rebuildable at any moment
  from `Anemos.Runtime.PolicyStore` — which is what `init/1` does, so that
  a crash costs a dispatch cycle rather than every loaded policy.
  """

  use GenServer
  require Logger

  @behaviour Comn

  alias Anemos.Runtime.{DataStore, ModuleRegistry, PolicyStore, StoreSupervisor, SubscribableRegistry, TripleStore}
  alias Anemos.Runtime.ConditionServer
  alias Anemos.Runtime.ContextScope

  # Ceiling on re-entrant event dispatch (`emit ... as`, `nextevent`,
  # `nextrule`). Matches @while_limit in Anemos.Compiler: a policy author
  # gets one bound to reason about, not two. Without it, a two-rule cycle
  # spins the dispatcher at 100% CPU until the VM dies, and the caller sees
  # only a GenServer timeout.
  @max_event_depth 10_000

  # --- Client API ---

  @doc """
  Starts a dispatcher.

  ## Options

    * `:registry` — pid or name of a `ModuleRegistry` (required)
    * `:store_supervisor` — pid or name of a `StoreSupervisor` (required)
    * `:policy_store` — pid or name of a `PolicyStore` (required)
    * `:rule_supervisor` — pid or name of a `RuleSupervisor` (optional)
    * `:name` — process registration name (optional)

  Rules, conditions and capabilities are *not* passed here. They are read
  from the policy store, which is the only thing that survives a restart.
  Use `Anemos.Runtime.Standalone.start_link/1` to wire up a dispatcher and
  its stores outside a full `Anemos.Runtime` tree.
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the store supervisor and policy store this dispatcher reads from.
  """
  @spec topology(pid() | atom()) :: %{store_supervisor: pid(), policy_store: pid()}
  def topology(dispatcher), do: GenServer.call(dispatcher, :topology)

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

  @doc """
  Registers a `Subscribable` handler module for the given protocol string.
  """
  @spec register_subscribable(pid() | atom(), String.t(), module()) :: :ok
  def register_subscribable(dispatcher, protocol, handler_module) do
    GenServer.call(dispatcher, {:register_subscribable, protocol, handler_module})
  end

  # --- Server callbacks ---

  @impl true
  def init(opts) do
    state = %{
      rules: [],
      index: %{},
      registry: Keyword.fetch!(opts, :registry),
      store_supervisor: Keyword.fetch!(opts, :store_supervisor),
      policy_store: Keyword.fetch!(opts, :policy_store),
      rule_supervisor: Keyword.get(opts, :rule_supervisor),
      condition_servers: %{},
      condition_contexts: %{},
      capability_servers: %{},
      triple_store: nil,
      data_store: nil,
      subscribable_registry: nil,
      channel_connector: Anemos.Channel.Logger,
      rule_bindings: %{}
    }

    policy_store = state.policy_store

    state =
      %{state | channel_connector: PolicyStore.connector(policy_store)}
      |> refresh_stores()

    # Rebuild the derived view from the durable one. On a first start this
    # is a no-op; on a restart it is the difference between the policy set
    # firing and dispatch silently returning [].
    #
    # Replay failures are logged inside apply_compiled/2 and dropped here:
    # there is no caller to return them to, and refusing to start over an
    # inert data block would trade a degraded runtime for no runtime.
    state =
      Enum.reduce(PolicyStore.all(policy_store), state, fn compiled, st ->
        {st, _failures} = apply_compiled(compiled, st)
        st
      end)

    {:ok, state}
  end

  @impl true
  def handle_call(:topology, _from, state) do
    {:reply, %{store_supervisor: state.store_supervisor, policy_store: state.policy_store}, state}
  end

  @impl true
  def handle_call({:dispatch, event_name, context}, _from, state) do
    state = refresh_stores(state)
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

        # Drain what the condition servers sent us. Both message kinds are
        # collected in one pass so they stay in arrival order: a condition
        # emits its side effects before it announces its transition, and
        # reordering them would run a CONDITION_<name> rule before the body
        # that provoked it.
        condition_messages = collect_condition_messages()

        # Dispatch original event to matching rules
        {results, state} = dispatch_to_rules(event_name, context, state, 0)

        {condition_results, state} =
          Enum.reduce(condition_messages, {[], state}, fn message, {acc, st} ->
            {res, st} = apply_condition_message(message, context, st)
            {acc ++ res, st}
          end)

        {results ++ condition_results, state}
      end)

    {:reply, results, state}
  end

  @impl true
  def handle_call({:load, compiled}, _from, state) do
    state = refresh_stores(state)

    # Record before applying: the policy store is the source of truth, and a
    # crash midway through apply_compiled/2 must still leave the policy
    # recoverable on restart.
    :ok = PolicyStore.put(state.policy_store, compiled)

    {state, failures} = apply_compiled(compiled, state)

    # Same convention as Scheduler.schedule/2: :ok means every declaration
    # in this result is live, {:error, failures} means the policy loaded but
    # the listed declarations are inert. Previously these were Logger
    # warnings and nothing else, so the caller could not tell.
    reply = if failures == [], do: :ok, else: {:error, Enum.reverse(failures)}
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:condition_state, name}, _from, state) do
    state = refresh_stores(state)

    case Map.get(state.condition_servers, name) do
      %{pid: pid} -> {:reply, ConditionServer.get_state(pid), state}
      nil -> {:reply, nil, state}
    end
  end

  @impl true
  def handle_call({:data_member?, name, value}, _from, state) do
    state = refresh_stores(state)
    result = DataStore.member?(state.data_store, name, value)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:set_connector, connector}, _from, state) do
    :ok = PolicyStore.put_connector(state.policy_store, connector)
    {:reply, :ok, %{state | channel_connector: connector}}
  end

  @impl true
  def handle_call({:register_subscribable, protocol, handler_module}, _from, state) do
    state = refresh_stores(state)
    :ok = SubscribableRegistry.register(state.subscribable_registry, protocol, handler_module)
    {:reply, :ok, state}
  end

  # Turns one compilation result into running processes and index entries.
  # Called both from {:load, _} and from init/1 when replaying the policy
  # store, so a rebuilt dispatcher is wired identically to a freshly loaded
  # one.
  defp apply_compiled(compiled, state) do
    dispatcher_pid = self()

    # Condition and capability servers are (re)started under the store
    # supervisor, not linked here. put_condition/3 replaces any existing
    # server for the name so that a restarted dispatcher installs
    # transition callbacks pointing at itself.
    Enum.each(compiled.conditions, fn cond_spec ->
      {:ok, _pid} =
        StoreSupervisor.put_condition(
          state.store_supervisor,
          cond_spec,
          fn name -> send(dispatcher_pid, {:condition_transition, name}) end,
          # Both callbacks `send` rather than `call`, and must. They run
          # inside the condition server's handle_cast, at a moment when the
          # dispatcher is blocked in ConditionServer.get_state/1 waiting for
          # that very cast to drain. A call back into the dispatcher here
          # deadlocks. The operations are picked up from the mailbox in
          # handle_call({:dispatch, ...}) and executed there, inside the
          # dispatch cycle that produced them.
          fn name, ops -> send(dispatcher_pid, {:condition_side_effects, name, ops}) end
        )
    end)

    # The dispatcher only learns a condition's name from the callbacks, so
    # it keeps the declared context alongside in order to stamp
    # `:_rule_source` when the body's operations run. Rebuilt on every
    # apply_compiled/2, which covers the init/1 replay as well as {:load, _}.
    condition_contexts =
      Enum.reduce(compiled.conditions, state.condition_contexts, fn cond_spec, acc ->
        Map.put(acc, cond_spec.name, Map.get(cond_spec, :context))
      end)

    state = %{state | condition_contexts: condition_contexts}

    Enum.each(compiled.capabilities, fn cap ->
      {:ok, _pid} = StoreSupervisor.put_capability(state.store_supervisor, cap)
    end)

    # Register data blocks (static and dynamic). A data block whose
    # subscription never starts is inert: the block exists and every
    # memberof() against it answers false, forever. That is a load failure
    # the author has to hear about, not a log line.
    failures =
      Enum.reduce(Map.get(compiled, :data_blocks, []), [], fn data, failures ->
        if data.dataset do
          DataStore.register(state.data_store, data.name, data.scope || :global, data.dataset,
            source: data.source)
        end

        case data.dynamic do
          {{:subscribe, protocol, uri}, _periodic} ->
            subscribe_data_block(data, protocol, uri, state, failures)

          _ ->
            failures
        end
      end)

    merged_rules = state.rules ++ compiled.rules

    # Condition/capability pids are never cached in state — refresh_stores/1
    # reads them from the supervisor so a restarted server is picked up.
    state = refresh_stores(%{state | rules: merged_rules, index: build_index(merged_rules)})

    {state, failures}
  end

  defp subscribe_data_block(data, protocol, uri, state, failures) do
    case SubscribableRegistry.lookup(state.subscribable_registry, protocol) do
      {:ok, handler} ->
        scope = data.scope || :global
        DataStore.register(state.data_store, data.name, scope, MapSet.new())

        callback = fn new_data ->
          dataset = if is_list(new_data), do: MapSet.new(new_data), else: new_data
          DataStore.update(state.data_store, data.name, scope, dataset)
        end

        case handler.subscribe(protocol, uri, callback) do
          {:ok, _ref} ->
            Logger.debug("Started subscription for data block '#{data.name}' via #{protocol}")
            failures

          {:error, reason} ->
            Logger.warning(
              "data block '#{data.name}' not subscribed: #{inspect(reason)} — it will never update"
            )

            [{:data_block, data.name, {:subscribe_failed, reason}} | failures]
        end

      :error ->
        Logger.warning(
          "data block '#{data.name}' names protocol '#{protocol}', which has no registered " <>
            "handler — it will never update"
        )

        [{:data_block, data.name, {:no_subscribable_handler, protocol}} | failures]
    end
  end

  # Resolves every supervised child by id, once per callback. Cheaper than a
  # monitor-and-invalidate scheme and, unlike a cached pid, cannot hand a
  # dead process to a rule body mid-dispatch.
  defp refresh_stores(state) do
    snap = StoreSupervisor.snapshot(state.store_supervisor)

    %{
      state
      | triple_store: snap.triple_store,
        data_store: snap.data_store,
        subscribable_registry: snap.subscribable_registry,
        condition_servers: Map.new(snap.conditions, fn {name, pid} -> {name, %{pid: pid}} end),
        capability_servers: snap.capabilities
    }
  end

  @impl true
  def handle_info({:dwell_fire, rule_name, event_name}, state) do
    state = refresh_stores(state)
    rule_state = Map.get(state.rule_bindings, rule_name, %{})
    dwell_key = {:dwell, event_name}

    case Map.get(rule_state, dwell_key) do
      %{state: :armed, last_context: context} when context != nil ->
        rule = Enum.find(state.rules, fn r -> r.name == rule_name and event_name in r.subscriptions end)

        new_state =
          if rule do
            {_results, st_after_run} = dispatch_immediate(rule, event_name, context, [], state, 0)

            # dispatch_immediate writes handler persistent bindings back to
            # rule_bindings[rule_name], which may wipe dwell entries for other
            # events on the same rule. Merge: take the post-run handler state,
            # then layer back all dwell entries from the pre-run snapshot except
            # the one we just fired (reset that to :listening).
            pre_run_dwell_entries =
              rule_state
              |> Enum.filter(fn {k, _} -> match?({:dwell, _}, k) end)
              |> Map.new()

            handler_state = Map.get(st_after_run.rule_bindings, rule_name, %{})

            updated_rule_state =
              handler_state
              |> Map.merge(pre_run_dwell_entries)
              |> Map.put(dwell_key, %{state: :listening, timer_ref: nil, last_context: nil})

            put_in(st_after_run.rule_bindings[rule_name], updated_rule_state)
          else
            state
          end

        {:noreply, new_state}

      _ ->
        # Stale fire — rule was cancelled or already fired. Drop silently.
        {:noreply, state}
    end
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

  defp dispatch_to_rules(event_name, context, state, depth) do
    state.index
    |> Map.get(event_name, [])
    |> Enum.map(&{&1, event_name})
    |> dispatch_rules(event_name, context, state, depth)
  end

  # The single entry point into rule execution. Everything that reaches a
  # rule handler goes through here — the event index, `emit ... as`,
  # `nextevent` and `nextrule` — so the context filter and the dwell branch
  # cannot be skipped by picking a different caller. `nextrule` used to
  # reimplement a subset of this and consulted neither (A-39).
  #
  # Takes `{rule, event_name}` pairs rather than an event name because
  # `nextrule` selects rules by *rule* name and still needs a real event
  # name to hand the handler and to key dwell state by.
  #
  # Re-entrant dispatch is bounded, not truncated and not fatal: the caller
  # gets a structured error naming the target it gave up on, and the
  # dispatcher stays alive to serve the next request.
  defp dispatch_rules(_pairs, label, _context, state, depth) when depth >= @max_event_depth do
    {[{:error, recursion_error(label)}], state}
  end

  defp dispatch_rules(pairs, _label, context, state, depth) do
    event_context = Map.get(context, :context_path)

    pairs
    |> Enum.filter(fn {rule, _event_name} -> context_matches?(rule, event_context) end)
    |> Enum.reduce({[], state}, fn {rule, event_name}, {results_acc, st} ->
      case Map.get(rule, :dwell_duration_ms) do
        nil ->
          dispatch_immediate(rule, event_name, context, results_acc, st, depth)

        ms when is_integer(ms) ->
          new_st = handle_dwell_event(rule, event_name, context, ms, st)
          {results_acc, new_st}
      end
    end)
  end

  defp recursion_error(event_name) do
    Comn.Errors.Registry.error!("anemos.runtime/event_recursion_limit",
      message:
        "Event recursion exceeded #{@max_event_depth} levels while dispatching '#{event_name}' — " <>
          "check for a cycle between emit/nextevent/nextrule targets"
    )
  end

  defp dispatch_immediate(rule, event_name, context, results_acc, st, depth) do
    persistent = Map.get(st.rule_bindings, rule.name, %{})

    # Pass DataStore pid and rule name through context so compiled closures
    # can resolve memberof() with per-rule scope
    enriched_context =
      context
      |> Map.put(:data_store, st.data_store)
      |> Map.put(:_rule_name, rule.name)

    case safe_handle(rule, event_name, enriched_context, persistent) do
      {:ok, ops, new_persistent} ->
        new_st = put_in(st.rule_bindings[rule.name], new_persistent)
        rule_context = Map.get(rule, :meta, %{}) |> Map.get(:context_path)
        exec_context = Map.put(context, :_rule_source, {rule.name, rule_context})

        # execute_op/4 returns {results, state}: `nextevent` and `nextrule`
        # re-enter dispatch, and the state they produce — persistent `set`
        # bindings, dwell timers — has to come back out. Threading it
        # through the fold is what A-16 was missing.
        {all_results, new_st} =
          Enum.reduce(ops, {[], new_st}, fn op, {acc, st_op} ->
            {res, st_op} = execute_op(op, exec_context, st_op, depth)
            {acc ++ List.wrap(res), st_op}
          end)

        {normal_results, emit_events} =
          Enum.split_with(all_results, fn
            {:emit_event, _, _} -> false
            _ -> true
          end)

        {emit_results, new_st} =
          Enum.reduce(emit_events, {[], new_st}, fn {:emit_event, label, op}, {acc, s} ->
            {sub_results, s} = dispatch_to_rules(label, context, s, depth + 1)
            {acc ++ [{:ok, op} | sub_results], s}
          end)

        {results_acc ++ normal_results ++ emit_results, new_st}

      {:error, reason} ->
        err = Comn.Errors.Registry.error!("anemos.runtime/handler_crash",
          message: "Rule #{rule.name} raised: #{inspect(reason)}")
        {results_acc ++ [{:error, err}], st}
    end
  end

  # Fails closed on an event that names no context: see ContextScope.
  defp context_matches?(rule, event_context) do
    ContextScope.within?(event_context, get_in(rule, [Access.key(:meta), :context_path]))
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

  # Every clause returns `{results, state}`. Only the re-entrant ones can
  # actually change the state, but a uniform shape is what lets
  # dispatch_immediate/6 fold over the op list without knowing which is which.
  defp execute_op(%{type: :command, module: mod_name, verb: verb, args: args}, context, state, _depth) do
    result =
      case ModuleRegistry.lookup(state.registry, mod_name) do
        {:ok, mod} -> mod.handle_verb(verb, args, context)
        :error ->
          {:error, Comn.Errors.Registry.error!("anemos.runtime/unknown_module",
            message: "Module #{mod_name} not found in registry")}
      end

    {result, state}
  end

  defp execute_op(%{type: :log, value: value} = op, _context, state, _depth) do
    Logger.info("[anemos] #{value}")
    {{:ok, op}, state}
  end

  defp execute_op(%{type: :emit} = op, context, state, _depth) do
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
    result =
      if is_binary(op[:label]) do
        {:emit_event, op.label, op}
      else
        {:ok, op}
      end

    {result, state}
  end

  defp execute_op(%{type: :demand, capability: cap_name} = op, context, state, _depth) do
    demands = [%{capability: cap_name, flag: Map.get(op, :flag, :requisite)}]

    results =
      case Anemos.Runtime.Demand.evaluate(demands, state.capability_servers, context) do
        {:ok, ops} -> Enum.map(ops, fn result_op -> {:ok, result_op} end)
        {:error, _} = err -> [err]
      end

    {results, state}
  end

  defp execute_op(%{type: :assert_triple, subject: s, predicate: p, object: o} = op, _context, state, _depth) do
    TripleStore.assert_triple(state.triple_store, s, p, o)
    {{:ok, op}, state}
  end

  defp execute_op(%{type: :triple_query} = op, _context, state, _depth) do
    s = triple_query_pattern(op.subject)
    p = triple_query_pattern(op.predicate)
    o = triple_query_pattern(op.object)
    results = TripleStore.match(state.triple_store, s, p, o)
    {{:ok, %{type: :triple_result, query: op, results: results}}, state}
  end

  defp execute_op(%{type: :nextevent, target: target}, context, state, depth) do
    dispatch_to_rules(target, context, state, depth + 1)
  end

  # Selects rules by *rule* name and then hands them to the same
  # dispatch_rules/5 the event index uses, so a `nextrule` target gets the
  # context filter and the dwell branch applied to it (A-39) and its
  # persistent bindings come back out (A-16).
  #
  # The handler is given the rule's own first subscription as the event
  # name. The old synthetic `"nextrule:<target>"` matched no subscription,
  # which meant guards and dwell keys saw an event name that could never
  # occur in a real dispatch.
  defp execute_op(%{type: :nextrule, target: target} = op, context, state, depth) do
    pairs =
      for rule <- state.rules, rule.name == target do
        {rule, nextrule_event_name(rule, target)}
      end

    dispatch_rules(
      pairs,
      "nextrule:#{target}",
      nextrule_context(context, Map.get(op, :args)),
      state,
      depth + 1
    )
  end

  defp execute_op(%{type: :register_data, data: data}, context, state, _depth) do
    if data.dataset do
      scope = case data.scope do
        :local ->
          # Use rule name as scope discriminator — rules don't run as separate
          # processes, so pid-based scoping would collapse all inline blocks
          # into one scope (the dispatcher's pid).
          rule_name = case context[:_rule_source] do
            {name, _} -> name
            _ -> "unknown"
          end
          {:local, rule_name}
        _ ->
          data.scope || :global
      end
      DataStore.register(state.data_store, data.name, scope, data.dataset)
    end
    {{:ok, %{type: :register_data, name: data.name}}, state}
  end

  defp execute_op(%{type: :register_query, query: query}, _context, state, _depth) do
    {{:ok, %{type: :register_query, name: query.name}}, state}
  end

  defp nextrule_event_name(rule, target) do
    case rule.subscriptions do
      [event_name | _] -> event_name
      _ -> "nextrule:#{target}"
    end
  end

  # `nextrule foo { a: 1 }` delivers its arguments as event context data, so
  # the target reads them with `?a` exactly as it would read a real event
  # payload. Nothing produces these yet — see the note in the report —
  # but the delivery path is here rather than dropping them silently.
  defp nextrule_context(context, args) when is_map(args) and map_size(args) > 0 do
    Map.update(context, :context_data, args, fn existing ->
      Map.merge(existing || %{}, args)
    end)
  end

  defp nextrule_context(context, _args), do: context

  # --- Dwell timer state machine ---
  #
  # State per (rule_name, event_name) is stored in rule_bindings under the key
  # {:dwell, event_name} as %{state: :listening | :armed, timer_ref: ref | nil,
  # last_context: map() | nil}.
  #
  # The spec's `:activated` state is collapsed here: the body runs synchronously
  # inside handle_info({:dwell_fire, ...}), which IS the activated phase. We
  # never persist `:activated` — the state transitions directly from `:armed`
  # back to `:listening` after the body completes.
  #
  # Transitions:
  #   :listening + truthy  -> :armed  (arm timer)
  #   :listening + falsy   -> :listening (no-op)
  #   :armed     + truthy  -> :armed  (no restart, update last_context)
  #   :armed     + falsy   -> :listening (cancel timer)
  #   timer fires          -> run body, return to :listening
  #
  # See docs/superpowers/specs/2026-05-18-elseif-and-dwell-timer-design.md.

  defp handle_dwell_event(rule, event_name, context, ms, st) do
    truthy? = dwell_signal_truthy?(context)
    rule_state = Map.get(st.rule_bindings, rule.name, %{})
    dwell_key = {:dwell, event_name}
    current = Map.get(rule_state, dwell_key, %{state: :listening, timer_ref: nil, last_context: nil})

    new_dwell =
      case {current.state, truthy?} do
        {:listening, true} ->
          ref = Process.send_after(self(), {:dwell_fire, rule.name, event_name}, ms)
          %{state: :armed, timer_ref: ref, last_context: context}

        {:listening, false} ->
          current

        {:armed, true} ->
          # No restart — keep existing timer, update last_context.
          %{current | last_context: context}

        {:armed, false} ->
          if current.timer_ref, do: Process.cancel_timer(current.timer_ref, info: false)
          %{state: :listening, timer_ref: nil, last_context: nil}
      end

    new_rule_state = Map.put(rule_state, dwell_key, new_dwell)
    put_in(st.rule_bindings[rule.name], new_rule_state)
  end

  defp dwell_signal_truthy?(context) do
    payload = Map.get(context, :context_data) || %{}

    cond do
      Map.has_key?(payload, "state") -> truthy?(Map.get(payload, "state"))
      Map.has_key?(payload, :state) -> truthy?(Map.get(payload, :state))
      true -> true
    end
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  defp triple_query_pattern({:var, _} = var), do: var
  defp triple_query_pattern(literal), do: literal
end

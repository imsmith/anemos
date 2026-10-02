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

  alias Anemos.Runtime.{
    DataStore,
    ModuleRegistry,
    PolicyStore,
    StoreSupervisor,
    SubscribableRegistry,
    TripleStore
  }

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

  Declarations from different policies accumulate. A rule name that is
  already loaded is **replaced**, not appended — see the `{:load, _}`
  callback for why replacement rather than rejection.
  """
  @spec load(pid() | atom(), Anemos.CompilationResult.t()) :: :ok | {:error, [term()]}
  def load(dispatcher, compiled) do
    GenServer.call(dispatcher, {:load, compiled})
  end

  @doc """
  Unloads the named rules.

  Removes them from the rule set and the index, cancels any dwell timer they
  have armed, drops their rule-scoped data blocks, and removes them from the
  policy store so a dispatcher restart does not bring them back. Rule names
  that are not loaded are ignored.

  Rules only. Conditions, capabilities and global data blocks are not owned
  by a rule — a policy-level unload would need a policy identity, which
  `Anemos.CompilationResult` does not carry.
  """
  @spec unload(pid() | atom(), [String.t()]) :: :ok
  def unload(dispatcher, rule_names) when is_list(rule_names) do
    GenServer.call(dispatcher, {:unload, rule_names})
  end

  @typedoc "What a deploy changed that the caller has to act on."
  @type deploy_diff :: %{removed_schedules: [String.t()]}

  @doc """
  Deploys `compiled` as the policy `id`, over whatever was last deployed
  under that id.

  Afterwards the dispatcher holds what `compiled` declares and nothing the
  previous version declared that it does not. A rule or condition whose
  fingerprint is unchanged keeps its state; see the `{:deploy, ...}`
  callback.

  Answers `{load_result, diff}`, where `load_result` is what `load/2` would
  answer and `diff` names the schedules the caller must disarm — the
  scheduler is not the dispatcher's to call. A policy that declares a name
  another identified policy holds is not loaded at all: `{:refused, message}`.
  """
  @spec deploy(pid() | atom(), String.t(), Anemos.CompilationResult.t(), map()) ::
          {:ok | {:error, [term()]}, deploy_diff()} | {:refused, String.t()}
  def deploy(dispatcher, id, compiled, fingerprints) when is_binary(id) do
    GenServer.call(dispatcher, {:deploy, id, compiled, fingerprints})
  end

  @doc """
  Removes the policy `id` and everything it declared.
  """
  @spec undeploy(pid() | atom(), String.t()) :: {:ok, deploy_diff()} | {:error, :not_loaded}
  def undeploy(dispatcher, id) when is_binary(id) do
    GenServer.call(dispatcher, {:undeploy, id})
  end

  @doc """
  The loaded policies in load order, each with the names it declares. A load
  that named no policy has `id: nil`.
  """
  @spec policies(pid() | atom()) :: [map()]
  def policies(dispatcher), do: GenServer.call(dispatcher, :policies)

  @doc """
  Returns the names of the rules currently loaded, without duplicates.

  A rule with several `when` blocks compiles to several rules sharing one
  name and is reported once.
  """
  @spec rules(pid() | atom()) :: [String.t()]
  def rules(dispatcher), do: GenServer.call(dispatcher, :rules)

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
      rule_bindings: %{},
      # {data block name, scope} => {handler, ref} for live `subscribe`
      # feeds, so the feed can be cancelled when its block goes.
      subscriptions: %{}
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
        # Route event to all condition servers (async cast). A condition
        # evaluates expressions the same way a rule does, so it is given the
        # same expression-position authority (A-56) — with its own name and
        # declared context as the source, which is what
        # apply_condition_message/3 stamps on the operations its body
        # produces.
        Enum.each(state.condition_servers, fn {name, %{pid: pid}} ->
          ConditionServer.handle_event(pid, event_name, condition_context(name, context, state))
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

  # A deploy is a load that knows what it replaces. Everything the previous
  # version of the policy declared and this one does not is torn down, in
  # this one call, so no event is ever dispatched against half of each.
  #
  # State follows the text. A rule or condition whose fingerprint matches
  # the previous version's is the same declaration — the edit was elsewhere
  # in the file — and keeps its `set` bindings, armed dwell timers and
  # boolean state. One whose text changed starts from nothing, for the
  # reason merge_rules/3 gives.
  @impl true
  def handle_call({:deploy, id, compiled, fingerprints}, _from, state) do
    state = refresh_stores(state)
    entries = PolicyStore.entries(state.policy_store)
    old = Enum.find(entries, &(&1.id == id))
    others = Enum.reject(entries, &(&1.id == id))

    case conflicts(id, compiled, others) do
      [] ->
        {state, diff} = retire(state, old, compiled, others)

        # Recorded before applying, as in {:load, _}.
        :ok = PolicyStore.put(state.policy_store, id, compiled, fingerprints)

        prior = %{unchanged: unchanged(old, fingerprints), own: own_rules(old)}
        {state, failures} = apply_compiled(compiled, state, prior)
        reply = if failures == [], do: :ok, else: {:error, Enum.reverse(failures)}
        {:reply, {reply, diff}, state}

      conflicts ->
        {:reply, {:refused, Enum.join(conflicts, "; ")}, state}
    end
  end

  @impl true
  def handle_call({:undeploy, id}, _from, state) do
    state = refresh_stores(state)
    entries = PolicyStore.entries(state.policy_store)

    case Enum.find(entries, &(&1.id == id)) do
      nil ->
        {:reply, {:error, :not_loaded}, state}

      old ->
        :ok = PolicyStore.delete(state.policy_store, id)
        others = Enum.reject(entries, &(&1.id == id))
        {state, diff} = retire(state, old, %Anemos.CompilationResult{}, others)
        {:reply, {:ok, diff}, refresh_stores(state)}
    end
  end

  @impl true
  def handle_call(:policies, _from, state) do
    policies =
      for %{id: id, compiled: c} <- PolicyStore.entries(state.policy_store) do
        %{
          id: id,
          rules: c.rules |> Enum.map(& &1.name) |> Enum.uniq(),
          conditions: Enum.map(c.conditions, & &1.name),
          capabilities: Enum.map(c.capabilities, & &1.name),
          schedules: c.schedules |> Enum.map(& &1.event_name) |> Enum.uniq(),
          data_blocks: Enum.map(c.data_blocks, & &1.name)
        }
      end

    {:reply, policies, state}
  end

  @impl true
  def handle_call({:unload, rule_names}, _from, state) do
    state = refresh_stores(state)
    drop = MapSet.new(rule_names)

    # The durable record first, for the same reason load/2 records before
    # applying: if this crashes halfway, a restart must not resurrect what
    # the caller asked to remove.
    :ok = PolicyStore.drop_rules(state.policy_store, rule_names)

    remaining = Enum.reject(state.rules, &MapSet.member?(drop, &1.name))

    state =
      state
      |> purge_rule_state(drop)
      |> drop_rule_data(drop)

    {:reply, :ok, %{state | rules: remaining, index: build_index(remaining)}}
  end

  @impl true
  def handle_call(:rules, _from, state) do
    {:reply, state.rules |> Enum.map(& &1.name) |> Enum.uniq(), state}
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

  # Rule, condition and capability names are global in a runtime. A policy
  # that declares one another *identified* policy holds is refused whole:
  # replacing it would silently stop part of an unrelated policy (A-61), and
  # here, unlike in an anonymous load, both parties have names to report.
  defp conflicts(id, compiled, others) do
    for %{id: other, compiled: theirs} when is_binary(other) <- others,
        {kind, field} <- [rule: :rules, condition: :conditions, capability: :capabilities],
        name <- names(compiled, field),
        name in names(theirs, field) do
      "policy #{inspect(id)} declares #{kind} #{inspect(name)}, which policy " <>
        "#{inspect(other)} already declares"
    end
  end

  defp names(compiled, field),
    do: compiled |> Map.fetch!(field) |> Enum.map(& &1.name) |> Enum.uniq()

  defp data_keys(compiled) do
    for %{scope: scope} = data <- compiled.data_blocks, scope in [nil, :global] do
      {data.name, :global}
    end
  end

  # The rules and conditions whose text did not change between two versions
  # of a policy.
  defp unchanged(nil, _fingerprints), do: MapSet.new()

  defp unchanged(%{fingerprints: old}, new) do
    for {key, digest} <- new, Map.get(old, key) == digest, into: MapSet.new(), do: key
  end

  defp own_rules(nil), do: MapSet.new()
  defp own_rules(%{compiled: compiled}), do: MapSet.new(compiled.rules, & &1.name)

  # Tears down what `old` declared and `new` does not. `others` are the
  # policies that stay loaded: a schedule's name is its time, so two policies
  # can share one timer and it must outlive either of them alone.
  defp retire(state, nil, _new, _others), do: {state, %{removed_schedules: []}}

  defp retire(state, %{compiled: old}, new, others) do
    gone_rules = MapSet.new(names(old, :rules) -- names(new, :rules))

    rules = Enum.reject(state.rules, &MapSet.member?(gone_rules, &1.name))

    state =
      %{state | rules: rules, index: build_index(rules)}
      |> purge_rule_state(gone_rules)
      |> drop_rule_data(gone_rules)

    gone_conditions = names(old, :conditions) -- names(new, :conditions)
    Enum.each(gone_conditions, &StoreSupervisor.delete(state.store_supervisor, {:condition, &1}))

    Enum.each(
      names(old, :capabilities) -- names(new, :capabilities),
      &StoreSupervisor.delete(state.store_supervisor, {:capability, &1})
    )

    state =
      Enum.reduce(data_keys(old) -- data_keys(new), state, fn {name, scope} = key, st ->
        DataStore.deregister(st.data_store, name, scope)
        unsubscribe(st, key)
      end)

    still_declared =
      for %{compiled: c} <- others, s <- c.schedules, into: MapSet.new(), do: s.event_name

    removed_schedules =
      (Enum.map(old.schedules, & &1.event_name) -- Enum.map(new.schedules, & &1.event_name))
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(still_declared, &1))

    state = %{state | condition_contexts: Map.drop(state.condition_contexts, gone_conditions)}
    {state, %{removed_schedules: removed_schedules}}
  end

  defp unsubscribe(state, key) do
    case Map.pop(state.subscriptions, key) do
      {{handler, ref}, subscriptions} ->
        handler.unsubscribe(ref)
        %{state | subscriptions: subscriptions}

      {nil, _} ->
        state
    end
  end

  # Turns one compilation result into running processes and index entries.
  # Called both from {:load, _} and from init/1 when replaying the policy
  # store, so a rebuilt dispatcher is wired identically to a freshly loaded
  # one.
  #
  # `prior` is what a deploy knows about the version it replaces:
  # `unchanged`, the `{:rule | :condition, name}` it found identical to what
  # is already running, and `own`, the rule names that version declared.
  # Both are empty for a plain load and for the init/1 replay, where every
  # server must be installed afresh.
  @no_prior %{unchanged: MapSet.new(), own: MapSet.new()}

  defp apply_compiled(compiled, state, %{unchanged: unchanged} = prior \\ @no_prior) do
    dispatcher_pid = self()

    # Condition and capability servers are (re)started under the store
    # supervisor, not linked here. put_condition/4 replaces any existing
    # server for the name so that a restarted dispatcher installs
    # callbacks pointing at itself.
    compiled.conditions
    |> Enum.reject(&MapSet.member?(unchanged, {:condition, &1.name}))
    |> Enum.each(fn cond_spec ->
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
    {state, failures} =
      Enum.reduce(Map.get(compiled, :data_blocks, []), {state, []}, fn data, {state, failures} ->
        if data.dataset do
          DataStore.register(state.data_store, data.name, data.scope || :global, data.dataset,
            source: data.source
          )
        end

        case data.dynamic do
          {{:subscribe, protocol, uri}, _periodic} ->
            subscribe_data_block(data, protocol, uri, state, failures)

          _ ->
            # Static now, whatever it was before.
            {unsubscribe(state, {data.name, data.scope || :global}), failures}
        end
      end)

    {state, merged_rules} = merge_rules(state, compiled.rules, prior)

    # Condition/capability pids are never cached in state — refresh_stores/1
    # reads them from the supervisor so a restarted server is picked up.
    state = refresh_stores(%{state | rules: merged_rules, index: build_index(merged_rules)})

    {state, failures}
  end

  # Rules from different policies accumulate; a rule *name* that is already
  # loaded is replaced by the incoming definition.
  #
  # Appending unconditionally was A-15: loading the same policy twice put two
  # copies of every rule in the index, and every event fired each of them —
  # so a re-load was not idempotent and a hot-reload doubled execution on
  # each pass.
  #
  # Replace rather than reject. Rejecting a duplicate name has nowhere to go
  # in the contract `Anemos.Runtime.load/3` publishes — `{:partial, failures}`
  # would report a successful redefinition as a failure — and rejection makes
  # the common case, reloading an edited policy, impossible without an unload
  # first. The redefinition is logged instead, because silently changing what
  # a rule name means is worth a line in the log.
  #
  # Replacement is by name and takes *all* of a name's rules with it: a rule
  # with several `when` blocks compiles to several `CompiledRule` structs
  # sharing one name, and dropping them individually would leave half of the
  # old definition running alongside the new one.
  defp merge_rules(state, [], _prior), do: {state, state.rules}

  defp merge_rules(state, incoming, %{unchanged: unchanged, own: own}) do
    incoming_names = MapSet.new(incoming, & &1.name)

    replaced =
      state.rules
      |> Enum.filter(&MapSet.member?(incoming_names, &1.name))
      |> Enum.map(& &1.name)
      |> Enum.uniq()

    # A policy deployed over itself redefines its own rules by design; what
    # is worth a line is a rule taken from somewhere else.
    taken = Enum.reject(replaced, &MapSet.member?(own, &1))

    if taken != [] do
      Logger.info(
        "[anemos] redefining rule(s) #{Enum.join(taken, ", ")} — the previous definition " <>
          "is no longer loaded"
      )
    end

    kept = Enum.reject(state.rules, &MapSet.member?(incoming_names, &1.name))

    # The old definition's persistent `set` bindings and armed dwell timers
    # describe a rule body that no longer exists. Carrying them into the new
    # definition hands it state it never produced, and leaves a
    # `{:dwell_fire, ...}` in flight for a `when` block that may be gone.
    #
    # Unless the definition is the same one: a deploy that found the rule's
    # text unchanged is replacing it with itself, and it keeps what it has.
    changed = Enum.reject(replaced, &MapSet.member?(unchanged, {:rule, &1}))
    state = purge_rule_state(state, MapSet.new(changed))

    {state, kept ++ incoming}
  end

  # Forgets the per-rule execution state the dispatcher holds for the named
  # rules: persistent `set` bindings and armed dwell timers.
  #
  # The dwell timers have to be cancelled explicitly. Dropping the binding
  # alone leaves the `Process.send_after/3` armed; it fires, finds no entry
  # and is discarded as stale — harmless in itself, but it is a timer the
  # runtime cannot account for, and for a rule reloaded in between it lands
  # on a definition that never armed it.
  #
  # Rule-scoped *data* is deliberately not touched here, because this runs
  # on replacement as well as on unload and a replacement has already
  # re-registered its inline `data` blocks by the time it reaches this
  # point — dropping the scope would delete what the incoming policy just
  # registered. Unload does that separately, in drop_rule_data/2.
  defp purge_rule_state(state, names) do
    if MapSet.size(names) == 0 do
      state
    else
      Enum.each(names, fn name ->
        state.rule_bindings
        |> Map.get(name, %{})
        |> Enum.each(fn
          {{:dwell, _event}, %{timer_ref: ref}} when is_reference(ref) ->
            Process.cancel_timer(ref, info: false)

          _other ->
            :ok
        end)
      end)

      %{state | rule_bindings: Map.drop(state.rule_bindings, MapSet.to_list(names))}
    end
  end

  # Rule-local `data` blocks are scoped by rule name (see execute_op/4 for
  # :register_data). Nothing else will ever remove them: a rule name is not
  # a process, so the DataStore has nothing to monitor and no `:DOWN` to act
  # on (A-24). Unload is the only point at which they are known to be dead.
  defp drop_rule_data(state, names) do
    if state.data_store do
      Enum.each(names, &DataStore.drop_scope(state.data_store, {:local, &1}))
    end

    state
  end

  defp subscribe_data_block(data, protocol, uri, state, failures) do
    case SubscribableRegistry.lookup(state.subscribable_registry, protocol) do
      {:ok, handler} ->
        scope = data.scope || :global
        # A block that is being re-registered already has a feed; a second
        # one would deliver every update twice and could never be cancelled.
        state = unsubscribe(state, {data.name, scope})
        DataStore.register(state.data_store, data.name, scope, MapSet.new())

        callback = fn new_data ->
          dataset = if is_list(new_data), do: MapSet.new(new_data), else: new_data
          DataStore.update(state.data_store, data.name, scope, dataset)
        end

        case handler.subscribe(protocol, uri, callback) do
          {:ok, ref} ->
            Logger.debug("Started subscription for data block '#{data.name}' via #{protocol}")
            subscriptions = Map.put(state.subscriptions, {data.name, scope}, {handler, ref})
            {%{state | subscriptions: subscriptions}, failures}

          {:error, reason} ->
            # A-52 site 3. Same split as crash_error/2, one severity lower.
            # The block name is authored text and stays; the handler's reason
            # is runtime data from a subsystem that was, by definition, in
            # the middle of authenticating, so only its tag survives into the
            # log. The full reason is not lost — it rides the structured
            # failure back to whoever called `load/2`, who is the embedder
            # rather than the log.
            Logger.warning(
              "data block '#{data.name}' not subscribed (#{reason_tag(reason)}) — it will " <>
                "never update; the reason is on the failure returned by load/2"
            )

            {state, [{:data_block, data.name, {:subscribe_failed, reason}} | failures]}
        end

      :error ->
        Logger.warning(
          "data block '#{data.name}' names protocol '#{protocol}', which has no registered " <>
            "handler — it will never update"
        )

        {state, [{:data_block, data.name, {:no_subscribable_handler, protocol}} | failures]}
    end
  end

  # A `{:tag, value}` reason names its failure mode in the head and carries
  # values in the tail. The head comes from the host's own Subscribable
  # implementation — authored, not attacker-supplied — so it is safe to
  # print and is the single most useful token an operator gets. Everything
  # else is described by shape only.
  defp reason_tag(tag) when is_atom(tag), do: inspect(tag)

  defp reason_tag(reason) when is_tuple(reason) and tuple_size(reason) > 0 do
    case elem(reason, 0) do
      tag when is_atom(tag) -> inspect(tag)
      _ -> Anemos.Redact.summarize(reason)
    end
  end

  defp reason_tag(reason), do: Anemos.Redact.summarize(reason)

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
        rule =
          Enum.find(state.rules, fn r -> r.name == rule_name and event_name in r.subscriptions end)

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

  @impl true
  def handle_info({:condition_side_effects, _name, _ops}, state) do
    # Same as above. A condition can only transition in response to an event
    # the dispatcher itself cast to it, so reaching this clause means the
    # cast outlived its dispatch cycle — there is no cycle left to execute
    # the operations in, and no caller to return them to.
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
      operations: [
        :command,
        :log,
        :emit,
        :demand,
        :assert_triple,
        :triple_query,
        :nextevent,
        :nextrule
      ]
    }
  end

  @impl Comn
  # Only what act/1 below actually implements. "load" and "condition_state"
  # were advertised here and handled by nothing, so a Comn caller taking
  # this list at its word got {:error, :unknown_action}. Loading in
  # particular must not be advertised on a generic action surface at all
  # (A-12) — `Anemos.Runtime.load/3` is the sole entry point and the place
  # the authority is consulted.
  def choices do
    %{actions: ["dispatch"]}
  end

  @impl Comn
  def act(%{action: :dispatch, pid: pid, event: event, context: ctx}),
    do: {:ok, dispatch(pid, event, ctx)}

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

  # The condition-side counterpart of the `enriched_context` in
  # dispatch_immediate/6: what a condition's evaluator and body may reach
  # while evaluating expressions. `:_verb_context` is built from the raw
  # `context` by the same verb_context/2 the statement path uses, so a verb
  # called from a condition sees exactly what it sees from a rule. It does
  # not contain `:registry`: that key is evaluation authority for the
  # closure and must not be forwarded into `handle_verb/3`.
  #
  # `:data_store` is deliberately absent: it is scoped per *rule* name and a
  # condition is not a rule. memberof() in a condition answers false, as it
  # did before A-56.
  defp condition_context(name, context, state) do
    source = {name, Map.get(state.condition_contexts, name)}

    context
    |> Map.put(:registry, state.registry)
    |> Map.put(:_verb_context, verb_context(context, source))
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
    rule_context = Map.get(rule, :meta, %{}) |> Map.get(:context_path)

    # Authority handed to the compiled closure, and to nothing else:
    #
    #   * `:data_store` + `:_rule_name` — memberof() with per-rule scope;
    #   * `:registry` — expression-position `[MODULE::verb]` calls (A-56);
    #   * `:_verb_context` — the context those calls hand to host code,
    #     built here by the same verb_context/2 run_ops/5 uses so the two
    #     positions present host code identical inputs.
    #
    # The first three are evaluation authority and stop at the closure.
    # `:_verb_context` is built from `context`, not from this map, which is
    # what keeps them out of `handle_verb/3` (A-11).
    enriched_context =
      context
      |> Map.put(:data_store, st.data_store)
      |> Map.put(:_rule_name, rule.name)
      |> Map.put(:registry, st.registry)
      |> Map.put(:_verb_context, verb_context(context, {rule.name, rule_context}))

    case safe_handle(rule, event_name, enriched_context, persistent) do
      {:ok, ops, new_persistent} ->
        new_st = put_in(st.rule_bindings[rule.name], new_persistent)

        {results, new_st} = run_ops(ops, {rule.name, rule_context}, context, new_st, depth)
        {results_acc ++ results, new_st}

      {:error, reason} ->
        {results_acc ++ [{:error, crash_error(rule, reason)}], st}
    end
  end

  # A-52 site 2.
  #
  # A crash reason routinely carries the arguments that provoked it — for
  # `[SECRET::unlock ...]` that is the credential — so `inspect(reason)`
  # belongs in neither the returned error nor the log. The split drawn here
  # is *structure stays, values go*:
  #
  #   * the returned error keeps the rule name, the exception module and the
  #     request id, and nothing else. Those are authored or structural; none
  #     of them is a value the policy supplied.
  #
  #   * the log line carries the same three plus a `Anemos.Redact.summarize/1`
  #     of the message, keyed by the request id, so an operator holding the
  #     error can find its context without the context being in the error.
  #
  #   * the exception's own message — the only part that actually names
  #     values — appears nowhere by default. `config :anemos,
  #     :log_crash_detail, true` restores it for a debugging session; it is
  #     opt-in because turning it on is a decision to disclose, and that
  #     decision belongs to the operator rather than to whoever wrote the
  #     rule that crashed.
  #
  # The request id comes off the error struct rather than being generated
  # here: `Comn.Errors` enriches it from the ambient `Comn.Contexts`, which
  # is the same id every other error in this dispatch cycle carries.
  defp crash_error(rule, reason) do
    {kind, detail} = crash_shape(reason)

    err =
      Comn.Errors.Registry.error!("anemos.runtime/handler_crash",
        field: rule.name,
        message: ""
      )

    ref = err.request_id || "unknown"

    Logger.error(
      "[anemos] rule handler crash request=#{ref} rule=#{rule.name} kind=#{kind} " <>
        "detail=#{crash_detail(detail)}"
    )

    %{err | message: "Rule #{rule.name} raised #{kind} — see log for request #{ref}"}
  end

  defp crash_shape({:exception, module, message}), do: {inspect(module), message}
  defp crash_shape({:throw, kind, reason}), do: {"#{kind}", reason}
  defp crash_shape(other), do: {"error", other}

  defp crash_detail(detail) do
    if Application.get_env(:anemos, :log_crash_detail, false) do
      inspect(detail)
    else
      Anemos.Redact.summarize(detail)
    end
  end

  # Executes a list of operations on behalf of a named declaration.
  #
  # `source` is `{name, context_path}` — a rule, or a condition whose body
  # produced these operations. It becomes `:_rule_source`, which is how a
  # `demand` learns which context it is standing in and how an `emit`
  # labels its envelope.
  #
  # Shared rather than duplicated on purpose: this is the one place an
  # operation is executed, so a new caller cannot arrive without the
  # context filter, the depth ceiling, or the state threading. The three
  # times something *did* arrive without them are A-16, A-39 and A-50.
  defp run_ops(ops, source, context, st, depth) do
    exec_context = verb_context(context, source)

    # execute_op/4 returns {results, state}: `nextevent` and `nextrule`
    # re-enter dispatch, and the state they produce — persistent `set`
    # bindings, dwell timers — has to come back out. Threading it
    # through the fold is what A-16 was missing.
    {all_results, st} =
      Enum.reduce(ops, {[], st}, fn op, {acc, st_op} ->
        {res, st_op} = execute_op(op, exec_context, st_op, depth)
        {acc ++ List.wrap(res), st_op}
      end)

    {normal_results, emit_events} =
      Enum.split_with(all_results, fn
        {:emit_event, _, _} -> false
        _ -> true
      end)

    {emit_results, st} =
      Enum.reduce(emit_events, {[], st}, fn {:emit_event, label, op}, {acc, s} ->
        {sub_results, s} = dispatch_to_rules(label, context, s, depth + 1)
        {acc ++ [{:ok, op} | sub_results], s}
      end)

    {normal_results ++ emit_results, st}
  end

  # Fails closed on an event that names no context: see ContextScope.
  defp context_matches?(rule, event_context) do
    ContextScope.within?(event_context, get_in(rule, [Access.key(:meta), :context_path]))
  end

  defp collect_condition_messages do
    collect_condition_messages([])
  end

  defp collect_condition_messages(acc) do
    receive do
      {:condition_transition, name} ->
        collect_condition_messages([{:transition, name} | acc])

      {:condition_side_effects, name, ops} ->
        collect_condition_messages([{:side_effects, name, ops} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp apply_condition_message({:transition, name}, context, state) do
    dispatch_to_rules("CONDITION_#{name}", context, state, 0)
  end

  # A condition body's operations are executed by the same run_ops/5 that
  # runs a rule handler's, at the same depth, with the same `:_rule_source`
  # stamp — so an `emit ... as` from a condition body re-enters
  # dispatch_to_rules/4 and is filtered by context_matches?/2 on the
  # receiving side, a `demand` is gated by the capability's context, and
  # the recursion ceiling applies. This is deliberately not a private
  # execution path: A-39 was one of those.
  defp apply_condition_message({:side_effects, name, ops}, context, state) do
    source = {name, Map.get(state.condition_contexts, name)}
    run_ops(ops, source, context, state, 0)
  end

  # Crash boundary for compiled rule handler closures. Catches exception types
  # that can arise from evaluated user-supplied .rule code. Unexpected exception
  # types are intentionally left to crash and restart via the supervisor.
  # The exception *module* is kept separately from its message because
  # crash_error/2 discloses the first and redacts the second: the module
  # names a failure mode, the message names the values that caused it.
  defp safe_handle(rule, event_name, context, persistent_bindings) do
    rule.handler.(event_name, context, persistent_bindings)
  rescue
    e in RuntimeError -> crashed(e)
    e in ArgumentError -> crashed(e)
    e in FunctionClauseError -> crashed(e)
    e in MatchError -> crashed(e)
    e in BadMapError -> crashed(e)
    e in KeyError -> crashed(e)
    e in UndefinedFunctionError -> crashed(e)
    e in ArithmeticError -> crashed(e)
  catch
    kind, reason -> {:error, {:throw, kind, reason}}
  end

  defp crashed(e), do: {:error, {:exception, e.__struct__, Exception.message(e)}}

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
  # Arguments reach here from policy literals and from event payloads, both
  # untrusted. `Anemos.Runtime.Module.schema_for/2` is consulted and
  # enforced *before* `handle_verb/3`, so no host module can be reached by a
  # caller that skipped the check (A-11). A module declaring no schema for
  # the verb is unvalidated, exactly as before.
  defp execute_op(
         %{type: :command, module: mod_name, verb: verb, args: args},
         context,
         state,
         _depth
       ) do
    {invoke_verb(state.registry, mod_name, verb, args, context), state}
  end

  # A `[MODULE::verb]` that failed while being evaluated as a *value*
  # (A-56). The compiled closure has nowhere to put an error mid-expression,
  # so it aborts the body and hands the error back as this operation, which
  # lands in the results list exactly where a statement-position failure
  # would. See the "Expression position" section of `Anemos.Compiler`.
  defp execute_op(%{type: :verb_error, error: error}, _context, state, _depth) do
    {{:error, error}, state}
  end

  # `log` prints its value verbatim, and that is the intended behaviour.
  #
  # A-52 originally called for summarizing this through `Anemos.Redact`.
  # That was withdrawn, and correctly: `log` is the policy author's
  # deliberate "print this" and the only debugging tool the language has.
  # Reducing `log "starting sync"` to a shape descriptor does not harden
  # anything — it deletes the feature, and an author who cannot see their
  # own values writes worse policy, not safer policy.
  #
  # The disclosure control on this path already exists and is the designed
  # one: `Anemos.Secret` implements `String.Chars`, so a wrapped secret
  # interpolates as "[REDACTED]" right here, for free. An *unwrapped* secret
  # reaching a `log` op is a host module that failed to wrap its return
  # value — which is what the A-11 argument schemas and `Anemos.Secret`
  # adoption address at the boundary where the value enters. It is not
  # something the dispatcher can fix by blinding every log statement.
  #
  # The distinction that matters, and the one sites 2 and 3 below turn on:
  # here the author *asked* for the value to be printed. There, a value
  # leaked out of an error nobody asked to see.
  #
  # `log_text/1` exists because interpolating the value directly raised
  # `Protocol.UndefinedError` and killed the dispatcher for anything without
  # a `String.Chars` implementation — a map, a list, a tuple. That was
  # reachable before A-56 (`log ?payload` on a structured event) and A-56
  # makes it ordinary, since a verb may now return a map into a binding.
  # `to_string/1` is still tried first, and only first, because that is the
  # branch `Anemos.Secret` redaction rides on.
  defp execute_op(%{type: :log, value: value} = op, _context, state, _depth) do
    Logger.info("[anemos] #{log_text(value)}")
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

    # A capability body evaluates expressions like any other body, so it is
    # given the same expression-position authority (A-56). `context` is
    # already the verb context of the demanding rule — `:_rule_source` and
    # all — which is what a verb called from the capability body should see,
    # and what `Demand` reads to decide whether the demand is in scope.
    cap_context =
      context
      |> Map.put(:registry, state.registry)
      |> Map.put(:_verb_context, context)

    results =
      case Anemos.Runtime.Demand.evaluate(demands, state.capability_servers, cap_context) do
        {:ok, ops} -> Enum.map(ops, fn result_op -> {:ok, result_op} end)
        {:error, _} = err -> [err]
      end

    {results, state}
  end

  defp execute_op(
         %{type: :assert_triple, subject: s, predicate: p, object: o} = op,
         _context,
         state,
         _depth
       ) do
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

  defp execute_op(%{type: :nextevent, target: target} = op, context, state, depth) do
    dispatch_to_rules(target, with_block_args(context, Map.get(op, :args)), state, depth + 1)
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
      with_block_args(context, Map.get(op, :args)),
      state,
      depth + 1
    )
  end

  defp execute_op(%{type: :register_data, data: data}, context, state, _depth) do
    if data.dataset do
      scope =
        case data.scope do
          :local ->
            # Use rule name as scope discriminator — rules don't run as separate
            # processes, so pid-based scoping would collapse all inline blocks
            # into one scope (the dispatcher's pid).
            rule_name =
              case context[:_rule_source] do
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

  @doc """
  Resolves `mod_name` in `registry`, validates `args`, and invokes `verb`.

  **This is the only path from a `[MODULE::verb]` call to host code**, and
  it is deliberately public so that it can be shared rather than copied.
  Both positions the language offers go through it:

    * statement position — `execute_op/4`, on the operation list a rule
      handler returned;
    * expression position — `Anemos.Compiler`, from inside the compiled
      closure, where the call's return value becomes the value of the
      expression (A-56).

  Sharing it is the point. A second implementation would be the fourth
  instance of the defect shape A-39, A-59 and the duplicated `gate/3` all
  had: a caller reaching the same destination by a path that skipped a
  check. Here the checks are `Anemos.Runtime.Module.schema_for/2`, the
  `Anemos.Runtime.ArgSchema` bounds and allow-lists, and
  `Anemos.Runtime.PathGuard` confinement — all of them A-11's, and all of
  them applied before `handle_verb/3` regardless of which position the call
  was written in.

  `context` is the *verb* context — the event context stamped with
  `:_rule_source`. It is not the closure's evaluation context: `:data_store`
  and `:registry` reach the closure and must not reach host verb code. See
  `verb_context/2`.

  A `nil` registry answers `unknown_module` rather than raising. A compiled
  closure invoked outside a dispatcher — a unit test, an embedder calling
  `handler.(event, %{}, %{})` directly — has no registry to be given, so
  this is a reachable state and it fails closed with a message that says why
  rather than resolving to `nil` and letting a guard read false.
  """
  @spec invoke_verb(GenServer.server() | nil, String.t(), String.t(), list(), map()) ::
          Anemos.Runtime.Module.verb_result()
  def invoke_verb(nil, mod_name, verb, _args, _context) do
    {:error,
     Comn.Errors.Registry.error!("anemos.runtime/unknown_module",
       field: "#{mod_name}::#{verb}",
       message:
         "Module #{mod_name} is not reachable here: this expression is evaluated " <>
           "without a module registry"
     )}
  end

  def invoke_verb(registry, mod_name, verb, args, context) do
    case ModuleRegistry.lookup(registry, mod_name) do
      {:ok, mod} ->
        validate_then_handle(mod, mod_name, verb, args, context)

      :error ->
        {:error,
         Comn.Errors.Registry.error!("anemos.runtime/unknown_module",
           message: "Module #{mod_name} not found in registry"
         )}
    end
  end

  @doc """
  Builds the context a host verb sees: the event context plus `:_rule_source`.

  One definition, used by `run_ops/5` for statement-position calls and by
  `dispatch_immediate/6` to precompute `:_verb_context` for expression-position
  ones, so the two positions cannot drift into showing host code different
  things. Note what it does *not* add: `:data_store` and `:registry` are
  closure-evaluation authority and stop at the closure.
  """
  @spec verb_context(map(), {String.t(), String.t() | nil}) :: map()
  def verb_context(context, source), do: Map.put(context, :_rule_source, source)

  defp validate_then_handle(mod, mod_name, verb, args, context) do
    schema = Anemos.Runtime.Module.schema_for(mod, verb)

    case Anemos.Runtime.ArgSchema.validate(schema, args, verb) do
      {:ok, validated} ->
        mod.handle_verb(verb, validated, context)

      {:error, message} ->
        {:error,
         Comn.Errors.Registry.error!("anemos.runtime/invalid_argument",
           field: "#{mod_name}::#{verb}",
           message: message
         )}
    end
  end

  defp log_text(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp nextrule_event_name(rule, target) do
    case rule.subscriptions do
      [event_name | _] -> event_name
      _ -> "nextrule:#{target}"
    end
  end

  # A `with { a: 1 }` block on `nextrule` or `nextevent` delivers its arguments
  # as event context data, so the target reads them with `?a` exactly as it
  # would read a real event payload. Both statements share this, so the two
  # cannot drift apart in what a payload means.
  #
  # The args are merged into the originating context rather than replacing it:
  # the target still sees the event that got here, with the block's pairs laid
  # over the top. Absent a block, args are nil and the context passes through.
  defp with_block_args(context, args) when is_map(args) and map_size(args) > 0 do
    Map.update(context, :context_data, args, fn existing ->
      Map.merge(existing || %{}, args)
    end)
  end

  defp with_block_args(context, _args), do: context

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

    current =
      Map.get(rule_state, dwell_key, %{state: :listening, timer_ref: nil, last_context: nil})

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

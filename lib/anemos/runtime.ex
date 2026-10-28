defmodule Anemos.Runtime do
  @moduledoc """
  Supervisable runtime interpreter for Anemos policies.

  Start a blank interpreter in your supervision tree, then load modules
  and policies into it dynamically.

  ## Usage

      # Start the interpreter
      children = [
        {Anemos.Runtime, name: :anemos}
      ]
      Supervisor.start_link(children, strategy: :one_for_one)

      # Register modules
      Anemos.Runtime.register(:anemos, "DEVICE", MyApp.Device)
      Anemos.Runtime.register(:anemos, "INFRA", MyApp.Infra)

      # Load policies
      Anemos.Runtime.load(:anemos, File.read!("policies/ddns.rule"))
      Anemos.Runtime.load(:anemos, File.read!("policies/garage.rule"))

      # Dispatch events
      Anemos.Runtime.dispatch(:anemos, "SENSOR_MOTION_DETECTED")

  ## Options

    * `:name` — required, used to register and address the runtime
    * `:keyring` — `%{signer_name => Comn.Secrets.Key.t()}` of **public**
      keys, used by `Anemos.Runtime.LoadAuthority.Signed` to verify the
      detached signature of a policy that declares `signed_by` (A-05).
      Defaults to empty, which means every declared signer is unknown and
      therefore refused. See `Anemos.Runtime.TrustStore`.
    * `:unsigned_policy` — `:strict | :warn | :permit` for sources that
      declare no signer at all. Defaults to `:permit`; see
      `Anemos.Runtime.TrustStore` for why the default is the insecure one
      and when that must be revisited.
    * `:watch` — a directory of `*.rule` files to keep deployed: saving a
      file deploys it, deleting it unloads it. See `Anemos.Runtime.Watcher`.
    * `:modules` — `%{"NAME" => module}` bound from the start, so that a
      policy deployed at boot already has them. `register/3` after start
      does the same thing later.
  """

  use Supervisor

  @behaviour Comn

  alias Anemos.Runtime.{
    ContextStore,
    Dispatcher,
    LoadAuthority,
    ModuleRegistry,
    PolicyStore,
    RuleSupervisor,
    Scheduler,
    StateTable,
    StoreSupervisor,
    TrustStore
  }

  @doc """
  Starts the runtime supervisor.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: sup_name(name))
  end

  @typedoc """
  One declaration that loaded but will never do anything.

  A structured error. Its `code` says what kind of declaration and why —
  `anemos.scheduler/<reason>` for a schedule, `anemos.data/<reason>` for a
  data block — and its `field` names the declaration: the synthetic `AT_*`
  event name for a schedule, the block name for a data block.
  """
  @type load_failure :: Comn.Errors.ErrorStruct.t()

  @doc """
  Loads a policy source string into the running interpreter. **Privileged.**

  Parses and compiles the source, then adds the resulting rules,
  conditions, and capabilities to the dispatcher and arms any schedules.
  Can be called multiple times — policies accumulate.

  ## Deploying: `policy: id`

  A load that names its policy replaces whatever was last loaded under that
  name, exactly: afterwards the runtime holds what this source declares and
  nothing the previous version declared that this one does not.

      Anemos.Runtime.load(:anemos, File.read!(path), policy: "garage/lights.rule")

  A rule or condition whose text did not change keeps its state — `set`
  bindings, armed dwell timers, the condition's boolean — however much of
  the file around it was edited. One whose text changed starts from nothing.
  A source that fails to load changes nothing; the deployed version keeps
  running. Declaring a rule, condition or capability name that another
  named policy holds is refused, and nothing is loaded.

  Without `:policy` the load is anonymous: it can only add, and replace
  rules by name — and not a name a named policy holds, which is refused the
  same way. The name is passed to the load authority as
  `Anemos.Runtime.LoadRequest`'s `policy`.

  ## This is the trust boundary

  Whoever controls `source` controls every verb registered in this runtime.
  The call is therefore gated (A-12): it is checked against a source-size
  ceiling, then handed to the module configured as `config :anemos,
  :load_authority` as an `Anemos.Runtime.LoadRequest`. It is also *not*
  reachable through `act/1` — see `Anemos.Runtime.LoadAuthority` for why
  each of those three is here and what each is worth.

  Pass whatever your authority needs to identify the caller as
  `:authorization`:

      Anemos.Runtime.load(:anemos, source, authorization: %{tenant: "acme", token: tok})

  The default authority permits everything, so an embedder that has not
  configured one sees the pre-A-12 behaviour unchanged.

  ## Return values

    * `:ok` — the whole policy loaded and every schedule armed.

    * `{:partial, failures}` — the policy loaded, but the listed
      declarations are inert and will never fire. `failures` is a list of
      `t:load_failure/0`. The rules, conditions and capabilities in the
      same source *did* load and will fire; this is not a rollback.

    * `{:error, reason}` — nothing loaded. The source failed to parse or
      compile, or the load was refused. A refusal is a
      `Comn.Errors.ErrorStruct` with code `anemos.runtime/load_denied`; a
      parse or compile failure is one with a code under `anemos.lexer/`,
      `anemos.parser/` or `anemos.compiler/`.

  The distinction between the last two is the point. Arming a schedule and
  starting a data block subscription are per-declaration best-effort — an
  interval below the floor or a protocol with no registered handler stops
  that one declaration, not the policy. Collapsing that into `{:error, _}`
  would claim the rules had not loaded, when they had; collapsing it into
  `:ok` (as this function used to) hides a policy that will never fire.

  ## Examples

      case Anemos.Runtime.load(:anemos, source) do
        :ok -> :ready
        {:partial, failures} -> Logger.warning("inert declarations: " <> inspect(failures))
        {:error, reason} -> {:error, reason}
      end

  """
  @spec load(atom(), String.t(), keyword()) ::
          :ok | {:partial, [load_failure()]} | {:error, Comn.Errors.ErrorStruct.t()}
  def load(name, source, opts \\ []) do
    # `LoadAuthority.gate/3` is the ceiling, the parse and the authority,
    # in that order and for the reasons documented there. Going through it
    # is not a convention this function observes — it is the only way to
    # get an AST for the compiler, which is what keeps a second entry
    # point from quietly growing a second set of security properties
    # (A-59).
    with {:ok, policy} <- policy_id(opts),
         {:ok, ast} <- LoadAuthority.gate(name, source, opts),
         {:ok, compiled, fingerprints} <- compile(ast) do
      install(name, policy, compiled, fingerprints)
    end
  end

  defp policy_id(opts) do
    case Keyword.fetch(opts, :policy) do
      :error ->
        {:ok, nil}

      {:ok, id} when is_binary(id) and id != "" ->
        {:ok, id}

      {:ok, _other} ->
        {:error,
         Comn.Errors.Registry.error!("anemos.runtime/invalid_option",
           field: "policy",
           message: "the :policy option must be a non-empty string"
         )}
    end
  end

  # Declaration by declaration, which is how the compiler works anyway: it
  # carries nothing from one top-level declaration to the next. Doing it out
  # here is what ties each compiled rule and condition back to the text it
  # came from, so a deploy can tell which of them an edit actually touched.
  defp compile(%Anemos.AST.Program{declarations: declarations}) do
    Enum.reduce_while(declarations, {:ok, %Anemos.CompilationResult{}, %{}}, fn decl,
                                                                                {:ok, acc, fps} ->
      case Anemos.Compiler.compile(%Anemos.AST.Program{declarations: [decl]}) do
        {:ok, one} ->
          merged =
            Map.merge(acc, one, fn
              :__struct__, struct, _ -> struct
              _field, left, right -> left ++ right
            end)

          {:cont, {:ok, merged, fingerprint(fps, one, decl)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  # Two declarations sharing a name are one rule to the dispatcher, so their
  # digests are folded together rather than the later one winning.
  defp fingerprint(fps, one, decl) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(without_positions(decl)))

    keys =
      Enum.map(one.rules, &{:rule, &1.name}) ++
        Enum.map(one.conditions, &{:condition, &1.name}) ++
        for(%Anemos.AST.DataDecl{} <- [decl], data <- one.data_blocks, do: {:data, data.name})

    Enum.reduce(Enum.uniq(keys), fps, fn key, fps ->
      Map.update(fps, key, digest, &:crypto.hash(:sha256, &1 <> digest))
    end)
  end

  # The same declaration further down the file is the same declaration.
  defp without_positions(%_{} = node) do
    node
    |> Map.from_struct()
    |> Map.delete(:line)
    |> without_positions()
    |> Map.put(:__node__, node.__struct__)
  end

  defp without_positions(%{} = map), do: Map.new(map, fn {k, v} -> {k, without_positions(v)} end)
  defp without_positions(list) when is_list(list), do: Enum.map(list, &without_positions/1)

  defp without_positions(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> without_positions() |> List.to_tuple()

  defp without_positions(other), do: other

  defp install(name, nil, compiled, _fingerprints) do
    case Dispatcher.load(dispatcher_name(name), compiled) do
      {:refused, error} ->
        {:error, error}

      result ->
        schedule_failures =
          if compiled.schedules == [] do
            []
          else
            scheduler_name(name) |> Scheduler.schedule(compiled.schedules) |> failures_of()
          end

        finish(failures_of(result) ++ schedule_failures)
    end
  end

  defp install(name, policy, compiled, fingerprints) do
    scheduler = scheduler_name(name)

    # A policy arriving fresh declares its one-shots afresh; a redeploy of
    # a policy already here does not re-run what it has already run.
    if policy not in Enum.map(policies(name), & &1.id),
      do: Scheduler.forget(scheduler, Enum.map(compiled.schedules, & &1.event_name))

    case Dispatcher.deploy(dispatcher_name(name), policy, compiled, fingerprints) do
      {:refused, error} ->
        {:error, error}

      result ->
        # The scheduler reconciles against everything loaded, so its
        # failures include other policies' inert schedules. Those were
        # reported to whoever loaded them.
        own = MapSet.new(compiled.schedules, & &1.event_name)

        schedule_failures =
          scheduler
          |> Scheduler.sync()
          |> failures_of()
          |> Enum.filter(&MapSet.member?(own, &1.field))

        finish(failures_of(result) ++ schedule_failures)
    end
  end

  defp finish([]), do: :ok
  defp finish(failures), do: {:partial, failures}

  @doc """
  Removes a policy that was loaded with `policy: policy_id`, and everything
  it declared: rules and their state, conditions, capabilities, global data
  blocks and their live feeds, and any schedule no other policy declares.

  Not gated: whoever can call it can remove any policy by name. The gated
  way is from inside a policy — `[POLICY::unload "id"]`, see
  `Anemos.Runtime.Modules.Policy` — where the authority that admitted the
  calling policy stands for the removal (A-81).
  """
  @spec unload(atom(), String.t()) :: :ok | {:error, Comn.Errors.ErrorStruct.t()}
  def unload(name, policy_id) when is_binary(policy_id) do
    schedules = for %{id: ^policy_id, schedules: s} <- policies(name), e <- s, do: e

    with :ok <- Dispatcher.undeploy(dispatcher_name(name), policy_id) do
      _ = Scheduler.forget(scheduler_name(name), schedules)
      _ = Scheduler.sync(scheduler_name(name))
      :ok
    end
  end

  @doc """
  The loaded policies in load order, each as
  `%{id, rules, conditions, capabilities, schedules, data_blocks}` with the
  names it declares. A load that named no policy has `id: nil`.
  """
  @spec policies(atom()) :: [map()]
  def policies(name), do: Dispatcher.policies(dispatcher_name(name))

  # Both Dispatcher.load/2 and Scheduler.schedule/2 answer :ok or
  # {:error, failures}, each failure a structured error.
  defp failures_of(:ok), do: []
  defp failures_of({:error, failures}) when is_list(failures), do: failures

  @doc """
  Registers a module with the runtime.

  Accepts either a module built with `use Anemos.Module` (which carries
  its own name), or a name string and module pair.

  ## Examples

      # Module with embedded name
      Anemos.Runtime.register(:anemos, MyApp.Anemos.Secret)

      # Explicit name
      Anemos.Runtime.register(:anemos, "DEVICE", MyApp.Device)

  """
  @spec register(atom(), module()) :: :ok
  def register(name, module) when is_atom(module) do
    module_name = module.__anemos_name__()
    ModuleRegistry.register(registry_name(name), module_name, module)
  end

  @spec register(atom(), String.t(), module()) :: :ok
  def register(name, module_name, module) do
    ModuleRegistry.register(registry_name(name), module_name, module)
  end

  @doc """
  Registers an `Anemos.DataModel` handler under the keyword it answers from
  `keyword/0`. The keyword then names a format in a `data` block
  (`data d { edn { ... } }`) and an engine in a `query` block.

  Like a module, a handler is the host's to supply: the runtime ships none.
  Register it before loading a policy that names it — a `data` block whose
  format has no handler is a failure of that `load/3`.
  """
  @spec register_data_model(atom(), module()) :: :ok
  def register_data_model(name, handler) when is_atom(handler) do
    Dispatcher.register_data_model(dispatcher_name(name), handler)
  end

  @doc """
  Stores context data for `?` variable resolution.
  """
  @spec put_context(atom(), String.t(), term()) :: :ok
  def put_context(name, key, value) do
    ContextStore.put(context_store_name(name), key, value)
  end

  @doc """
  Connects a channel connector to the runtime.

  The connector must implement the `Anemos.Channel` behaviour.
  Replaces the current connector (default: `Anemos.Channel.Logger`).
  """
  @spec connect(atom(), module()) :: :ok
  def connect(name, connector) do
    GenServer.call(dispatcher_name(name), {:set_connector, connector})
  end

  @doc """
  Dispatches an event into the running interpreter.

  Accepts either a string event name (with optional context map) or any
  value implementing the `Anemos.Event` protocol.

  ## Examples

      # String API
      Anemos.Runtime.dispatch(:anemos, "SENSOR_MOTION_DETECTED")
      Anemos.Runtime.dispatch(:anemos, "EVENT", %{context_path: "garage"})

      # Protocol API — any type that implements Anemos.Event
      Anemos.Runtime.dispatch(:anemos, my_mqtt_message)

      # Map shorthand
      Anemos.Runtime.dispatch(:anemos, %{name: "MOTION", context: "garage", payload: %{}})

  Options: `:timeout`, how long to wait for the rules to run (default
  5000 ms). A context map's `:correlation_id` is carried into the ambient
  `Comn` context the rules run under, so what they emit shares it.
  """
  @spec dispatch(atom(), String.t() | Anemos.Event.t(), map(), keyword()) :: {:ok, list()}
  def dispatch(name, event_name, context \\ %{}, opts \\ [])

  def dispatch(name, event_name, context, opts) when is_binary(event_name) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    raw_results = Dispatcher.dispatch(dispatcher_name(name), event_name, context, timeout)

    results =
      Enum.flat_map(raw_results, fn
        {:ok, value} -> [value]
        {:error, _} = err -> [err]
      end)

    {:ok, results}
  end

  def dispatch(name, event, _context, opts) do
    event_name = Anemos.Event.name(event)
    event_context = Anemos.Event.context(event)
    event_payload = Anemos.Event.payload(event)

    context = %{context_path: event_context, context_data: event_payload}
    dispatch(name, event_name, context, opts)
  end

  @doc """
  Raises an interaction into the interpreter: what `on <interaction>` blocks
  take, as `dispatch/4` is what `when <event>` blocks take.

  A `when` takes a report, with a truth that stands until the next report
  and feeds compound triggers, dwell and conditions. An `on` takes an
  occurrence: no truth, never remembered, fired once each time. A host may
  raise a keypress or a named interaction; `boot` and `shutdown` are raised
  by the runtime itself when a policy becomes active and when it stops
  being so.

      Anemos.Runtime.interact(:anemos, {:keypress, "ESC"})
      Anemos.Runtime.interact(:anemos, "USER_LOGIN", %{context_path: "console"})

  Context and payload mean what they mean for `dispatch/4`. Something that
  is not an interaction answers an `anemos.runtime/not_an_interaction`
  error in the results, as a reserved `ON_` name handed to `dispatch/4`
  answers `anemos.runtime/reserved_event`.
  """
  @spec interact(atom(), {:keypress, String.t()} | String.t(), map(), keyword()) :: {:ok, list()}
  def interact(name, interaction, context \\ %{}, opts \\ []) do
    case Anemos.Runtime.Interaction.from_host(interaction) do
      {:ok, inv} ->
        timeout = Keyword.get(opts, :timeout, 5_000)
        event_name = Anemos.Runtime.Interaction.event_name(inv)
        raw = Dispatcher.interact(dispatcher_name(name), event_name, context, timeout)

        {:ok,
         Enum.map(raw, fn
           {:ok, value} -> value
           {:error, _} = err -> err
         end)}

      {:error, _} = err ->
        {:ok, [err]}
    end
  end

  @doc """
  Returns the current boolean state of a named condition, or `nil` if not found.
  """
  @spec condition_state(atom(), String.t()) :: boolean() | nil
  def condition_state(name, condition_name) do
    Dispatcher.condition_state(dispatcher_name(name), condition_name)
  end

  @doc """
  Everything the runtime holds, as it stands now.

  `%{policies, rules, conditions, capabilities, data_blocks, schedules,
  modules}`. Each rule carries the policy that declared it, the events it
  listens for, its context, its `set` bindings and the state of its dwell
  timers; each condition its current value.

  Bindings are returned as they are. An `Anemos.Secret` stays wrapped.

  Options: `:timeout` (default 5000 ms), for each of the calls this makes.
  """
  @spec describe(atom(), keyword()) :: map()
  def describe(name, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    scheduler = scheduler_name(name)

    schedules =
      for s <- GenServer.call(scheduler, :schedules, timeout) do
        %{
          event: s.event_name,
          time_spec: s.time_spec,
          recurrence: s.recurrence,
          fired_at: GenServer.call(scheduler, {:fired_at, s.event_name}, timeout)
        }
      end

    dispatcher = dispatcher_name(name)

    dispatcher
    |> GenServer.call(:describe, timeout)
    |> Map.merge(%{
      policies: GenServer.call(dispatcher, :policies, timeout),
      schedules: Enum.sort_by(schedules, & &1.event),
      modules: ModuleRegistry.names(registry_name(name))
    })
  end

  @doc """
  What dispatching `event_name` would do, without doing it.

  `%{rules: [...], conditions: [...]}`. Each rule that listens for the event
  is listed with the policy that declared it and an `outcome`: `:fires`,
  `{:dwell, ms}` for a `when ... for` rule that would arm or hold its timer,
  `:not_true` for a compound `when (A AND B)` whose state the report would
  leave false,
  or `:context_mismatch` when its `context` does not admit `context`'s
  `:context_path`. `conditions` names the conditions that would evaluate.

  Nothing is evaluated: a guard, an `if`, or a verb called in an expression
  can still change what a rule that `:fires` goes on to do.

  Options: `:timeout` (default 5000 ms).
  """
  @spec explain(atom(), String.t(), map(), keyword()) :: %{
          rules: [map()],
          conditions: [String.t()]
        }
  def explain(name, event_name, context \\ %{}, opts \\ []) when is_binary(event_name) do
    Dispatcher.explain(
      dispatcher_name(name),
      event_name,
      context,
      Keyword.get(opts, :timeout, 5_000)
    )
  end

  @doc """
  The most recent dispatches, newest first.

  Each is `%{at, event, context_path, steps, conditions, results,
  duration_us}`. `steps` is every rule the event reached, in order, with
  what happened — `:fired`, `:dwell`, `:dwell_fired`, `:not_true` or
  `:context_mismatch` — including rules reached through `nextevent`, `nextrule` and `emit ...
  as`. `conditions` names the conditions that became true. `results` gives
  the kind of each operation; a `log` carries its text, since that was
  written to the log anyway, and nothing else carries a value.

  The last #{200} are kept, and they outlive a dispatcher crash — which is
  when they are wanted.
  """
  @spec trace(atom(), pos_integer()) :: [map()]
  def trace(name, limit \\ 50) when is_integer(limit) and limit > 0 do
    StateTable.recent(StateTable.name_for(name), :trace, limit)
  end

  # --- Supervisor callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

    # Owned by this supervisor process, so it outlives every child below.
    state_table = StateTable.new(name)

    # Ordered by dependency, shallowest first. Everything after a given
    # child depends on it: the dispatcher reads the module registry, the
    # policy store and the store supervisor; the scheduler dispatches into
    # the dispatcher.
    children = [
      # First, and started unconditionally even when nothing is configured
      # (A-05). `LoadAuthority.Signed` refuses any load into a runtime with
      # no trust store, because "I cannot decide" on a security boundary
      # has to mean refusal; always starting one keeps that refusal for
      # genuine failures instead of making it the normal case.
      {TrustStore,
       name: TrustStore.name_for(name),
       keyring: Keyword.get(opts, :keyring, %{}),
       unsigned_policy: Keyword.get(opts, :unsigned_policy, :permit)},
      {ModuleRegistry,
       name: registry_name(name),
       state_table: state_table,
       modules:
         Map.merge(%{"POLICY" => Anemos.Runtime.Modules.Policy}, Keyword.get(opts, :modules, %{}))},
      {ContextStore, name: context_store_name(name), state_table: state_table},
      {PolicyStore, name: policy_store_name(name), state_table: state_table},
      {StoreSupervisor, name: store_supervisor_name(name)},
      {RuleSupervisor, name: rule_supervisor_name(name)},
      {Dispatcher,
       name: dispatcher_name(name),
       registry: registry_name(name),
       policy_store: policy_store_name(name),
       store_supervisor: store_supervisor_name(name),
       rule_supervisor: rule_supervisor_name(name),
       state_table: state_table,
       runtime: name},
      {Scheduler,
       name: scheduler_name(name),
       runtime_name: name,
       policy_store: policy_store_name(name),
       state_table: state_table}
    ]

    # Last: it loads into everything above, and a restart of any of them
    # restarts it, which redeploys the directory into the fresh runtime.
    children =
      case Keyword.fetch(opts, :watch) do
        {:ok, dir} ->
          children ++
            [{Anemos.Runtime.Watcher, name: watcher_name(name), runtime: name, dir: dir}]

        :error ->
          children
      end

    # :rest_for_one, not :one_for_one. The dispatcher's state is derived
    # from the policy store and from the processes under the store
    # supervisor; if either restarts, the dispatcher's view of them is
    # stale and must be rebuilt. Under :one_for_one a store supervisor
    # restart would leave the dispatcher pointing at condition and
    # capability servers that no longer exist, which is the same silent
    # policy loss this rework exists to close — just one level up.
    #
    # A dispatcher crash on its own restarts only the dispatcher and the
    # scheduler behind it; the stores and the policy set are untouched,
    # which is the whole point.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  # --- Comn callbacks ---

  @impl Comn
  def look, do: "Runtime — supervisable event-driven policy interpreter"

  @impl Comn
  def recon do
    %{
      type: :facade,
      children: [
        :module_registry,
        :context_store,
        :policy_store,
        :store_supervisor,
        :rule_supervisor,
        :dispatcher,
        :scheduler
      ],
      api: [
        :load,
        :unload,
        :policies,
        :describe,
        :explain,
        :trace,
        :register,
        :dispatch,
        :connect,
        :put_context,
        :condition_state
      ],
      # Reported so that "we never configured an authority" is a fact an
      # operator can read off the running system rather than an absence.
      load_authority: LoadAuthority.configured()
    }
  end

  @impl Comn
  def choices do
    %{actions: ["register", "dispatch", "connect"]}
  end

  @impl Comn
  def act(%{action: :dispatch, name: name, event: event, context: ctx}),
    do: dispatch(name, event, ctx)

  def act(%{action: :dispatch, name: name, event: event}), do: dispatch(name, event)

  # `:load` is deliberately absent (A-12). It used to be here, which meant
  # anything able to reach the generic Comn action dispatcher could install
  # policy — and installing policy is installing code against every verb the
  # host has registered. Loading now has exactly one entry point, `load/3`,
  # which names its authority. A generic action router has no business
  # holding the privileged operation of the system.
  #
  # (The clause that used to be here also had to be careful not to wrap a
  # failed load as `{:ok, {:error, _}}`. Deleting the clause removes that
  # hazard rather than preserving it: there is no longer a second path whose
  # return convention can drift from `load/3`'s.)
  def act(_input), do: {:error, Comn.Errors.Registry.error!("anemos.runtime/unknown_action")}

  # --- Name helpers ---

  @doc "The registered name of the directory watcher started by `watch:`."
  @spec watcher_name(atom()) :: atom()
  def watcher_name(name), do: :"#{name}.watcher"

  defp sup_name(name), do: :"#{name}.supervisor"
  defp registry_name(name), do: :"#{name}.registry"
  defp context_store_name(name), do: :"#{name}.context_store"
  defp dispatcher_name(name), do: :"#{name}.dispatcher"
  defp scheduler_name(name), do: :"#{name}.scheduler"
  defp policy_store_name(name), do: :"#{name}.policy_store"
  defp store_supervisor_name(name), do: :"#{name}.store_supervisor"
  defp rule_supervisor_name(name), do: :"#{name}.rule_supervisor"
end

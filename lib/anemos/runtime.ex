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

  `{kind, name, reason}` — `kind` is `:schedule` or `:data_block`, `name`
  identifies the declaration (the synthetic `AT_*` event name for a
  schedule, the block name for a data block), and `reason` is the
  originating module's own failure term.
  """
  @type load_failure ::
          {:schedule | :data_block, String.t(), term()}

  @doc """
  Loads a policy source string into the running interpreter. **Privileged.**

  Parses and compiles the source, then adds the resulting rules,
  conditions, and capabilities to the dispatcher and arms any schedules.
  Can be called multiple times — policies accumulate.

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
      `Comn.Errors.ErrorStruct` with code `anemos.runtime/load_denied`;
      parse and compile failures keep their existing shape.

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
          :ok | {:partial, [load_failure()]} | {:error, String.t() | Comn.Errors.ErrorStruct.t()}
  def load(name, source, opts \\ []) do
    # `LoadAuthority.gate/3` is the ceiling, the parse and the authority,
    # in that order and for the reasons documented there. Going through it
    # is not a convention this function observes — it is the only way to
    # get an AST for the compiler, which is what keeps a second entry
    # point from quietly growing a second set of security properties
    # (A-59).
    with {:ok, ast} <- LoadAuthority.gate(name, source, opts),
         {:ok, compiled} <- Anemos.Compiler.compile(ast) do
      dispatcher_failures =
        dispatcher_name(name)
        |> Dispatcher.load(compiled)
        |> failures_of(fn {kind, decl, reason} -> {kind, decl, reason} end)

      schedule_failures =
        if compiled.schedules == [] do
          []
        else
          scheduler_name(name)
          |> Scheduler.schedule(compiled.schedules)
          |> failures_of(fn {event_name, reason} -> {:schedule, event_name, reason} end)
        end

      case dispatcher_failures ++ schedule_failures do
        [] -> :ok
        failures -> {:partial, failures}
      end
    end
  end

  # Both Dispatcher.load/2 and Scheduler.schedule/2 answer :ok or
  # {:error, failures}; they differ only in the shape of a failure entry.
  defp failures_of(:ok, _normalize), do: []

  defp failures_of({:error, failures}, normalize) when is_list(failures) do
    Enum.map(failures, normalize)
  end

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

  """
  @spec dispatch(atom(), String.t() | Anemos.Event.t(), map()) :: {:ok, list()}
  def dispatch(name, event_name, context \\ %{})

  def dispatch(name, event_name, context) when is_binary(event_name) do
    raw_results = Dispatcher.dispatch(dispatcher_name(name), event_name, context)

    results =
      Enum.flat_map(raw_results, fn
        {:ok, value} -> [value]
        {:error, _} = err -> [err]
      end)

    {:ok, results}
  end

  def dispatch(name, event, _context) do
    event_name = Anemos.Event.name(event)
    event_context = Anemos.Event.context(event)
    event_payload = Anemos.Event.payload(event)

    context = %{context_path: event_context, context_data: event_payload}
    dispatch(name, event_name, context)
  end

  @doc """
  Returns the current boolean state of a named condition, or `nil` if not found.
  """
  @spec condition_state(atom(), String.t()) :: boolean() | nil
  def condition_state(name, condition_name) do
    Dispatcher.condition_state(dispatcher_name(name), condition_name)
  end

  # --- Supervisor callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)

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
      {ModuleRegistry, name: registry_name(name)},
      {ContextStore, name: context_store_name(name)},
      {PolicyStore, name: policy_store_name(name)},
      {StoreSupervisor, name: store_supervisor_name(name)},
      {RuleSupervisor, name: rule_supervisor_name(name)},
      {Dispatcher,
       name: dispatcher_name(name),
       registry: registry_name(name),
       policy_store: policy_store_name(name),
       store_supervisor: store_supervisor_name(name),
       rule_supervisor: rule_supervisor_name(name)},
      {Scheduler, name: scheduler_name(name), runtime_name: name}
    ]

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
      api: [:load, :register, :dispatch, :connect, :put_context, :condition_state],
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
  def act(_input), do: {:error, :unknown_action}

  # --- Name helpers ---

  defp sup_name(name), do: :"#{name}.supervisor"
  defp registry_name(name), do: :"#{name}.registry"
  defp context_store_name(name), do: :"#{name}.context_store"
  defp dispatcher_name(name), do: :"#{name}.dispatcher"
  defp scheduler_name(name), do: :"#{name}.scheduler"
  defp policy_store_name(name), do: :"#{name}.policy_store"
  defp store_supervisor_name(name), do: :"#{name}.store_supervisor"
  defp rule_supervisor_name(name), do: :"#{name}.rule_supervisor"
end

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
  """

  use Supervisor

  alias Anemos.Runtime.{ContextStore, Dispatcher, ModuleRegistry, Scheduler}

  @doc """
  Starts the runtime supervisor.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: sup_name(name))
  end

  @doc """
  Loads a policy source string into the running interpreter.

  Parses and compiles the source, then adds the resulting rules,
  conditions, and capabilities to the dispatcher. Can be called
  multiple times — policies accumulate.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec load(atom(), String.t()) :: :ok | {:error, String.t()}
  def load(name, source) do
    with {:ok, ast} <- Anemos.Parser.parse(source),
         {:ok, compiled} <- Anemos.Compiler.compile(ast) do
      Dispatcher.load(dispatcher_name(name), compiled)
      if compiled.schedules != [] do
        Scheduler.schedule(scheduler_name(name), compiled.schedules)
      end
      :ok
    end
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

    children = [
      {ModuleRegistry, name: registry_name(name)},
      {ContextStore, name: context_store_name(name)},
      {Dispatcher,
       name: dispatcher_name(name),
       rules: [],
       registry: registry_name(name),
       conditions: [],
       capabilities: []},
      {Scheduler,
       name: scheduler_name(name),
       runtime_name: name}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Name helpers ---

  defp sup_name(name), do: :"#{name}.supervisor"
  defp registry_name(name), do: :"#{name}.registry"
  defp context_store_name(name), do: :"#{name}.context_store"
  defp dispatcher_name(name), do: :"#{name}.dispatcher"
  defp scheduler_name(name), do: :"#{name}.scheduler"
end

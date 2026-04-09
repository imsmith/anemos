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

  alias Anemos.Runtime.{ContextStore, Dispatcher, ModuleRegistry}

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
      :ok
    end
  end

  @doc """
  Registers an external module (e.g., `"DEVICE"`) with the runtime.

  Modules provide verb handlers for `[MODULE::verb]` commands in policies.
  Can be called at any time — modules accumulate.
  """
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
  Dispatches an event into the running interpreter.

  Returns `{:ok, results}` where results is a list of operation
  outputs and/or `{:error, reason}` tuples.
  """
  @spec dispatch(atom(), String.t(), map()) :: {:ok, list()}
  def dispatch(name, event_name, context \\ %{}) do
    raw_results = Dispatcher.dispatch(dispatcher_name(name), event_name, context)

    results =
      Enum.flat_map(raw_results, fn
        {:ok, value} -> [value]
        {:error, _} = err -> [err]
      end)

    {:ok, results}
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
       capabilities: []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Name helpers ---

  defp sup_name(name), do: :"#{name}.supervisor"
  defp registry_name(name), do: :"#{name}.registry"
  defp context_store_name(name), do: :"#{name}.context_store"
  defp dispatcher_name(name), do: :"#{name}.dispatcher"
end

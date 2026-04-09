defmodule Anemos.Runtime do
  @moduledoc """
  Supervisable runtime for Anemos policies.

  Add to your application's supervision tree to run policies as a
  long-lived, supervised process. Events can be dispatched into the
  running system, and `set` bindings persist across firings.

  ## Usage

      children = [
        {Anemos.Runtime,
          name: :my_policies,
          source: File.read!("policies/my.rule"),
          modules: %{"DEVICE" => MyApp.Device},
          context_data: %{"infra.dns.fqdn" => "host.example.tld"}}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

  Then dispatch events:

      Anemos.Runtime.dispatch(:my_policies, "SENSOR_MOTION_DETECTED")
      Anemos.Runtime.dispatch(:my_policies, "EVENT", %{context_path: "garage"})

  ## Options

    * `:name` — required, used to register and address the runtime
    * `:source` — rule source string (required)
    * `:modules` — map of module name to Elixir module, e.g. `%{"DEVICE" => MyApp.Device}` (optional)
    * `:context_data` — map of dotted-path keys to values for `?` variable resolution (optional)
  """

  use Supervisor

  alias Anemos.Runtime.{ContextStore, Dispatcher, ModuleRegistry}

  @doc """
  Starts the runtime supervisor.

  See module documentation for options.
  """
  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: sup_name(name))
  end

  @doc """
  Dispatches an event into a running runtime.

  ## Examples

      Anemos.Runtime.dispatch(:my_policies, "SENSOR_MOTION_DETECTED")
      Anemos.Runtime.dispatch(:my_policies, "EVENT", %{context_path: "garage"})

  """
  @spec dispatch(atom(), String.t(), map()) :: {:ok, list()} | {:error, term()}
  def dispatch(name, event_name, context \\ %{}) do
    dispatcher = dispatcher_name(name)
    raw_results = Dispatcher.dispatch(dispatcher, event_name, context)

    results =
      Enum.flat_map(raw_results, fn
        {:ok, value} -> [value]
        {:error, _} = err -> [err]
      end)

    {:ok, results}
  end

  @doc """
  Returns the current boolean state of a named condition.
  """
  @spec condition_state(atom(), String.t()) :: boolean() | nil
  def condition_state(name, condition_name) do
    Dispatcher.condition_state(dispatcher_name(name), condition_name)
  end

  # --- Supervisor callbacks ---

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    source = Keyword.fetch!(opts, :source)
    modules = Keyword.get(opts, :modules, %{})
    context_data = Keyword.get(opts, :context_data, %{})

    {:ok, ast} = Anemos.Parser.parse(source)
    {:ok, compiled} = Anemos.Compiler.compile(ast)

    children = [
      {ModuleRegistry, name: registry_name(name)},
      {ContextStore, name: context_store_name(name), data: Enum.to_list(context_data)},
      %{
        id: {__MODULE__, :setup, name},
        start: {__MODULE__, :setup_modules, [name, modules]},
        type: :worker,
        restart: :transient
      },
      {Dispatcher,
        name: dispatcher_name(name),
        rules: compiled.rules,
        registry: registry_name(name),
        conditions: compiled.conditions,
        capabilities: compiled.capabilities}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def setup_modules(name, modules) do
    registry = registry_name(name)

    Enum.each(modules, fn {mod_name, mod} ->
      ModuleRegistry.register(registry, mod_name, mod)
    end)

    :ignore
  end

  # --- Name helpers ---

  defp sup_name(name), do: :"#{name}.supervisor"
  defp registry_name(name), do: :"#{name}.registry"
  defp context_store_name(name), do: :"#{name}.context_store"
  defp dispatcher_name(name), do: :"#{name}.dispatcher"
end

defmodule Anemos.Runtime.ModuleRegistry do
  @moduledoc """
  Maps module names (e.g. "DEVICE", "FILE") to Elixir modules
  implementing the `Anemos.Runtime.Module` behaviour.

  ## Trust model

  This table decides where every `[MODULE::verb ...]` in every loaded policy
  executes. It is reachable by a documented public name
  (`:"\#{runtime_name}.registry"`), so any process in the VM can address it.
  Registration is therefore **write-once**: binding a name that is already
  live is refused and logged, so a later `register/3` cannot silently
  redirect `"SECRET"` or `"INFRA"` at a module of someone else's choosing
  while the policy continues to look normal from outside.

  Three outcomes:

    * name unbound — bound, logged at `:info`
    * name bound to the *same* module — idempotent `:ok` (host code and
      tests re-register defaults freely)
    * name bound to a *different* module — an
      `anemos.runtime/already_registered` error, logged at `:warning`,
      binding unchanged

  A deliberate rebind is still possible, but it has to say so:
  `register(reg, name, module, replace: true)`. That path also logs at
  `:warning`, because a verb changing destination mid-flight is an event an
  operator should see either way.

  This raises the bar from "any process can rebind" to "any process can
  rebind loudly, and only by asking". It is not an authorization check —
  there is no caller identity to check against. A registry that must not be
  written by arbitrary code should not be given a public name.
  """

  use Agent

  require Logger

  alias Anemos.Runtime.StateTable

  @behaviour Comn

  @doc """
  Starts a module registry.

  ## Options

    * `:name` — process registration name (optional)
    * `:state_table` — an `Anemos.Runtime.StateTable` the bindings are kept
      in, so that this process restarting does not lose them (A-43).
      Optional; without it a restarted registry is empty.
    * `:modules` — `%{name => module}` bound at start, under whatever the
      table remembers (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    table = Keyword.get(opts, :state_table)
    seed = Keyword.get(opts, :modules, %{})

    Agent.start_link(
      fn -> %{table: table, modules: Map.merge(seed, StateTable.get(table, :modules, %{}))} end,
      name: name
    )
  end

  @doc """
  Registers an Elixir module under the given name (e.g., `"DEVICE"`).

  Write-once. Re-registering the same module is idempotent; binding a live
  name to a different module is refused unless `replace: true` is given.
  Every outcome is logged. See the module docs for the trust model.

  ## Options

    * `:replace` — when `true`, deliberately rebind a live name (default `false`)

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
      iex> Anemos.Runtime.ModuleRegistry.register(reg, "DEVICE", Anemos.Runtime.Modules.Device)
      :ok
      iex> {:error, error} =
      ...>   Anemos.Runtime.ModuleRegistry.register(reg, "DEVICE", Anemos.Runtime.Modules.File)
      iex> error.code
      "anemos.runtime/already_registered"

  """
  @spec register(pid() | atom(), String.t(), module(), keyword()) ::
          :ok | {:error, Comn.Errors.ErrorStruct.t()}
  def register(registry, name, module, opts \\ []) do
    replace? = Keyword.get(opts, :replace, false)

    registry
    |> Agent.get_and_update(fn %{modules: modules} = state ->
      case Map.fetch(modules, name) do
        :error -> {:bound, bind(state, name, module)}
        {:ok, ^module} -> {:unchanged, state}
        {:ok, current} when replace? -> {{:replaced, current}, bind(state, name, module)}
        {:ok, current} -> {{:refused, current}, state}
      end
    end)
    |> log_outcome(name, module)
  end

  defp bind(%{table: table, modules: modules} = state, name, module) do
    modules = Map.put(modules, name, module)
    :ok = StateTable.put(table, :modules, modules)
    %{state | modules: modules}
  end

  defp log_outcome(:bound, name, module) do
    Logger.info("[anemos] module registered: #{name} -> #{inspect(module)}")
    :ok
  end

  defp log_outcome(:unchanged, name, module) do
    Logger.debug("[anemos] module re-registered unchanged: #{name} -> #{inspect(module)}")
    :ok
  end

  defp log_outcome({:replaced, current}, name, module) do
    Logger.warning(
      "[anemos] module binding replaced: #{name} was #{inspect(current)}, now #{inspect(module)}"
    )

    :ok
  end

  defp log_outcome({:refused, current}, name, module) do
    Logger.warning(
      "[anemos] module re-registration REFUSED: #{name} is bound to #{inspect(current)}, " <>
        "rejected #{inspect(module)}. Pass replace: true to rebind deliberately."
    )

    {:error,
     Comn.Errors.Registry.error!("anemos.runtime/already_registered",
       field: name,
       message: "#{name} is bound to #{inspect(current)}; pass replace: true to rebind it"
     )}
  end

  @doc """
  Returns true if `name` is currently bound.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
      iex> Anemos.Runtime.ModuleRegistry.registered?(reg, "DEVICE")
      false

  """
  @spec registered?(pid() | atom(), String.t()) :: boolean()
  def registered?(registry, name), do: Agent.get(registry, &Map.has_key?(&1.modules, name))

  @doc """
  Lists every bound module name, sorted. For auditing what a runtime can reach.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
      iex> Anemos.Runtime.ModuleRegistry.names(reg)
      []

  """
  @spec names(pid() | atom()) :: [String.t()]
  def names(registry), do: registry |> Agent.get(&Map.keys(&1.modules)) |> Enum.sort()

  @doc """
  Looks up a module by name.

  Returns `{:ok, module}` or `:error`.

  ## Examples

      iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
      iex> Anemos.Runtime.ModuleRegistry.lookup(reg, "MISSING")
      :error

  """
  @spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
  def lookup(registry, name) do
    case Agent.get(registry, &Map.get(&1.modules, name)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end

  # --- Comn callbacks ---

  @impl Comn
  def look, do: "ModuleRegistry — maps DSL module names to Elixir modules"

  @impl Comn
  def recon do
    %{
      type: :implementation,
      api: [:register, :lookup, :registered?, :names]
    }
  end

  @impl Comn
  def choices do
    %{actions: ["register", "lookup", "registered?", "names"]}
  end

  @impl Comn
  def act(%{action: :lookup, registry: reg, name: name}), do: {:ok, lookup(reg, name)}
  def act(_input), do: {:error, Comn.Errors.Registry.error!("anemos.runtime/unknown_action")}
end

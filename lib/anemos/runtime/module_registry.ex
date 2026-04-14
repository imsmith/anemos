defmodule Anemos.Runtime.ModuleRegistry do
  @moduledoc """
  Maps module names (e.g. "DEVICE", "FILE") to Elixir modules
  implementing the `Anemos.Runtime.Module` behaviour.
  """

  use Agent

  @behaviour Comn

  @doc """
  Starts a module registry.

  ## Options

    * `:name` — process registration name (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @doc """
  Registers an Elixir module under the given name (e.g., `"DEVICE"`).
  """
  @spec register(pid() | atom(), String.t(), module()) :: :ok
  def register(registry, name, module) do
    Agent.update(registry, &Map.put(&1, name, module))
  end

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
    case Agent.get(registry, &Map.get(&1, name)) do
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
      api: [:register, :lookup]
    }
  end

  @impl Comn
  def choices do
    %{actions: ["register", "lookup"]}
  end

  @impl Comn
  def act(%{action: :lookup, registry: reg, name: name}), do: {:ok, lookup(reg, name)}
  def act(_input), do: {:error, :unknown_action}
end

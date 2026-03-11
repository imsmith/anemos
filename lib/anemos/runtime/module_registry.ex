defmodule Anemos.Runtime.ModuleRegistry do
  @moduledoc """
  Maps module names (e.g. "DEVICE", "FILE") to Elixir modules
  implementing the `Anemos.Runtime.Module` behaviour.
  """

  use Agent

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    Agent.start_link(fn -> %{} end, name: name)
  end

  @spec register(pid() | atom(), String.t(), module()) :: :ok
  def register(registry, name, module) do
    Agent.update(registry, &Map.put(&1, name, module))
  end

  @spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
  def lookup(registry, name) do
    case Agent.get(registry, &Map.get(&1, name)) do
      nil -> :error
      mod -> {:ok, mod}
    end
  end
end

defmodule Anemos.Runtime.ContextStore do
  @moduledoc """
  Agent holding external key-value context data.
  Keys are dotted paths (e.g., "infra.networking.dns.fqdn").
  Resolution joins the context path with the variable name to form the lookup key.
  """

  use Agent

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    initial_data = Keyword.get(opts, :data, [])
    initial_map = Map.new(initial_data)
    Agent.start_link(fn -> initial_map end, name: name)
  end

  @spec put(pid() | atom(), String.t(), term()) :: :ok
  def put(store, key, value) do
    Agent.update(store, &Map.put(&1, key, value))
  end

  @spec resolve(pid() | atom(), String.t(), String.t()) :: {:ok, term()} | :error
  def resolve(store, context_path, name) do
    full_key = "#{context_path}.#{name}"
    case Agent.get(store, &Map.get(&1, full_key)) do
      nil -> :error
      value -> {:ok, value}
    end
  end
end

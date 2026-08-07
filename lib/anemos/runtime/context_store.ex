defmodule Anemos.Runtime.ContextStore do
  @moduledoc """
  Agent holding external key-value context data.
  Keys are dotted paths (e.g., "infra.networking.dns.fqdn").
  Resolution joins the context path with the variable name to form the lookup key.
  """

  use Agent

  @doc """
  Starts a context store.

  ## Options

    * `:data` — initial key-value pairs as a list of `{key, value}` tuples (optional)
    * `:name` — process registration name (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    initial_data = Keyword.get(opts, :data, [])
    initial_map = Map.new(initial_data)
    Agent.start_link(fn -> initial_map end, name: name)
  end

  @doc """
  Stores a key-value pair.
  """
  @spec put(pid() | atom(), String.t(), term()) :: :ok
  def put(store, key, value) do
    Agent.update(store, &Map.put(&1, key, value))
  end

  @doc """
  Resolves a variable name against a context path.

  Joins the context path and name with `.` to form the full key,
  then looks it up in the store.

  ## Examples

      iex> {:ok, store} = Anemos.Runtime.ContextStore.start_link(data: [{"infra.dns.fqdn", "host.example.tld"}])
      iex> Anemos.Runtime.ContextStore.resolve(store, "infra.dns", "fqdn")
      {:ok, "host.example.tld"}

      iex> {:ok, store} = Anemos.Runtime.ContextStore.start_link([])
      iex> Anemos.Runtime.ContextStore.resolve(store, "infra", "missing")
      :error

  """
  @spec resolve(pid() | atom(), String.t(), String.t()) :: {:ok, term()} | :error
  def resolve(store, context_path, name) do
    full_key = "#{context_path}.#{name}"

    case Agent.get(store, &Map.get(&1, full_key)) do
      nil -> :error
      value -> {:ok, value}
    end
  end
end

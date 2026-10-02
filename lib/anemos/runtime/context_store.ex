defmodule Anemos.Runtime.ContextStore do
  @moduledoc """
  Agent holding external key-value context data.
  Keys are dotted paths (e.g., "infra.networking.dns.fqdn").
  Resolution joins the context path with the variable name to form the lookup key.
  """

  use Agent

  alias Anemos.Runtime.StateTable

  @doc """
  Starts a context store.

  ## Options

    * `:data` — initial key-value pairs as a list of `{key, value}` tuples (optional)
    * `:name` — process registration name (optional)
    * `:state_table` — an `Anemos.Runtime.StateTable` the data is kept in,
      so that this process restarting does not lose it (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    table = Keyword.get(opts, :state_table)
    initial = opts |> Keyword.get(:data, []) |> Map.new()

    Agent.start_link(
      fn -> %{table: table, data: Map.merge(initial, StateTable.get(table, :context, %{}))} end,
      name: name
    )
  end

  @doc """
  Stores a key-value pair.
  """
  @spec put(pid() | atom(), String.t(), term()) :: :ok
  def put(store, key, value) do
    Agent.update(store, fn %{table: table, data: data} = state ->
      data = Map.put(data, key, value)
      :ok = StateTable.put(table, :context, data)
      %{state | data: data}
    end)
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

    case Agent.get(store, &Map.get(&1.data, full_key)) do
      nil -> :error
      value -> {:ok, value}
    end
  end
end

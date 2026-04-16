defmodule Anemos.Runtime.DataStore do
  @moduledoc """
  GenServer holding named datasets for data blocks.

  Entries are keyed by `{name, scope_tag}` where `scope_tag` is `:global`
  or `{:local, pid}`. Local entries shadow global entries during membership
  and get lookups. When a locally-scoped process dies, all entries scoped
  to that pid are automatically removed.

  ## Registering a dataset

      DataStore.register(store, "reserved-ips", :global,
        MapSet.new(["10.0.0.0/8", "192.168.0.0/16"]))

  ## Membership check (caller's local scope shadows global)

      DataStore.member?(store, "reserved-ips", "10.0.0.0/8")
      # => true

  ## Union membership across multiple sets

      DataStore.member_any?(store, ["blocklist", "denylist"], ip)

  ## Fetch full dataset

      DataStore.get(store, "reserved-ips")
      # => %MapSet{...}
  """

  use GenServer

  # ---------------------------------------------------------------------------
  # Client API
  # ---------------------------------------------------------------------------

  @doc """
  Starts a DataStore process.

  ## Options

    * `:name` — optional registration name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, %{entries: %{}, monitors: %{}}, name: name)
  end

  @doc """
  Registers (or replaces) a named dataset under a scope tag.

  `scope_tag` is `:global` or `{:local, pid}`.

  ## Options

    * `:source` — string describing origin
    * `:transcluded` — transcluded ref term
    * `:subscription` — monitor ref for live feeds
  """
  @spec register(GenServer.server(), String.t(), term(), term(), keyword()) :: :ok
  def register(store, name, scope_tag, dataset, opts \\ []) do
    GenServer.call(store, {:register, name, scope_tag, dataset, opts})
  end

  @doc """
  Removes a named entry for the given scope.
  """
  @spec deregister(GenServer.server(), String.t(), term()) :: :ok
  def deregister(store, name, scope_tag) do
    GenServer.call(store, {:deregister, name, scope_tag})
  end

  @doc """
  Returns true if `value` is a member of the named dataset.

  Checks local scope first (by `scope_hint` if provided, otherwise `self()`),
  then global.

  The optional `scope_hint` allows callers to specify a scope discriminator
  other than their pid — for example, a rule name string for per-rule scoping.
  """
  @spec member?(GenServer.server(), String.t(), term(), keyword()) :: boolean()
  def member?(store, name, value, opts \\ []) do
    scope_hint = Keyword.get(opts, :scope_hint, self())
    GenServer.call(store, {:member?, name, scope_hint, value})
  end

  @doc """
  Returns true if `value` is a member of any of the named datasets.
  """
  @spec member_any?(GenServer.server(), [String.t()], term(), keyword()) :: boolean()
  def member_any?(store, names, value, opts \\ []) do
    scope_hint = Keyword.get(opts, :scope_hint, self())
    GenServer.call(store, {:member_any?, names, scope_hint, value})
  end

  @doc """
  Returns the full dataset for `name`, or `nil` if not found.

  Checks local scope first, then global.
  """
  @spec get(GenServer.server(), String.t()) :: term() | nil
  def get(store, name) do
    GenServer.call(store, {:get, name, self()})
  end

  @doc """
  Replaces the dataset for an existing entry. Used by subscription callbacks.

  No-op if the entry does not exist.
  """
  @spec update(GenServer.server(), String.t(), term(), term()) :: :ok
  def update(store, name, scope_tag, dataset) do
    GenServer.call(store, {:update, name, scope_tag, dataset})
  end

  # ---------------------------------------------------------------------------
  # Server callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, name, scope_tag, dataset, opts}, _from, state) do
    entry = %{
      dataset: dataset,
      source: Keyword.get(opts, :source),
      transcluded: Keyword.get(opts, :transcluded),
      subscription: Keyword.get(opts, :subscription)
    }

    entries = Map.put(state.entries, {name, scope_tag}, entry)
    monitors = maybe_monitor(scope_tag, state.monitors)

    {:reply, :ok, %{state | entries: entries, monitors: monitors}}
  end

  def handle_call({:deregister, name, scope_tag}, _from, state) do
    entries = Map.delete(state.entries, {name, scope_tag})
    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:member?, name, caller_pid, value}, _from, state) do
    result =
      case resolve_entry(state.entries, name, caller_pid) do
        nil -> false
        entry -> dataset_member?(entry.dataset, value)
      end

    {:reply, result, state}
  end

  def handle_call({:member_any?, names, caller_pid, value}, _from, state) do
    result =
      Enum.any?(names, fn name ->
        case resolve_entry(state.entries, name, caller_pid) do
          nil -> false
          entry -> dataset_member?(entry.dataset, value)
        end
      end)

    {:reply, result, state}
  end

  def handle_call({:get, name, caller_pid}, _from, state) do
    result =
      case resolve_entry(state.entries, name, caller_pid) do
        nil -> nil
        entry -> entry.dataset
      end

    {:reply, result, state}
  end

  def handle_call({:update, name, scope_tag, dataset}, _from, state) do
    entries =
      case Map.fetch(state.entries, {name, scope_tag}) do
        {:ok, entry} -> Map.put(state.entries, {name, scope_tag}, %{entry | dataset: dataset})
        :error -> state.entries
      end

    {:reply, :ok, %{state | entries: entries}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    entries =
      state.entries
      |> Enum.reject(fn {{_name, scope_tag}, _entry} ->
        scope_tag == {:local, pid}
      end)
      |> Map.new()

    monitors = Map.delete(state.monitors, pid)

    {:noreply, %{state | entries: entries, monitors: monitors}}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Monitor a pid for local scope entries (once per pid).
  # Non-pid scope discriminators (e.g., rule name strings) are not monitored.
  defp maybe_monitor({:local, pid}, monitors) when is_pid(pid) do
    if Map.has_key?(monitors, pid) do
      monitors
    else
      ref = Process.monitor(pid)
      Map.put(monitors, pid, ref)
    end
  end

  defp maybe_monitor({:local, _name}, monitors), do: monitors
  defp maybe_monitor(:global, monitors), do: monitors

  # Resolve by checking local scope first, then global.
  defp resolve_entry(entries, name, caller_pid) do
    case Map.fetch(entries, {name, {:local, caller_pid}}) do
      {:ok, entry} -> entry
      :error ->
        case Map.fetch(entries, {name, :global}) do
          {:ok, entry} -> entry
          :error -> nil
        end
    end
  end

  defp dataset_member?(%MapSet{} = set, value), do: MapSet.member?(set, value)
  defp dataset_member?(list, value) when is_list(list), do: value in list
  defp dataset_member?(_other, _value), do: false
end

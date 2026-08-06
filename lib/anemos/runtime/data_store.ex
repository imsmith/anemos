defmodule Anemos.Runtime.DataStore do
  @moduledoc """
  GenServer holding named datasets for data blocks.

  Entries are keyed by `{name, scope_tag}` where `scope_tag` is `:global`
  or `{:local, discriminator}`. Local entries shadow global entries in every
  lookup.

  ## What a scope discriminator is

  Any term. It is *not* required to be a pid, and in the interpreter it
  usually is not: rules do not run as separate processes — every rule body
  executes inside the dispatcher — so a pid discriminator would collapse
  every rule's inline `data` block into one scope. `Anemos.Runtime.Dispatcher`
  therefore scopes rule-local blocks by rule *name*, and the compiled
  `memberof()` closure passes the same rule name as `:scope_hint`.

  Every lookup takes that hint the same way. `get/3` previously hardcoded
  `self()` while `member?/4` and `member_any?/4` honoured a `:scope_hint`,
  so `get` could not reach a rule-scoped entry at all — two lookup functions
  with two different scope models (A-24). The hint defaults to `self()`,
  which is what a host process registering data for itself wants.

  ## Cleanup

  Two paths, because only one of them can exist for a given discriminator:

    * **pid discriminators are monitored.** When the process dies, every
      entry scoped to it is removed. This is automatic and needs no caller.

    * **every other discriminator must be dropped explicitly**, with
      `drop_scope/2` or `deregister/3`. There is no process to watch, so
      there is nothing to make cleanup automatic — an unloaded policy's
      rule-scoped entries persist until something says to remove them, and
      before `drop_scope/2` existed nothing could. Reloading a policy
      re-registered under the same key, so entries did not multiply, but
      they also never went away.

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

  `scope_tag` is `:global` or `{:local, discriminator}` — see the moduledoc
  for what may be a discriminator and how each kind is cleaned up.

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
  Removes every entry registered under `scope_tag`.

  This is the cleanup path for scopes that cannot be monitored — a rule
  name, or any other non-pid discriminator. Idempotent.
  """
  @spec drop_scope(GenServer.server(), term()) :: :ok
  def drop_scope(store, scope_tag) do
    GenServer.call(store, {:drop_scope, scope_tag})
  end

  @doc """
  Returns true if `value` is a member of the named dataset.

  Checks local scope first (by `scope_hint` if provided, otherwise `self()`),
  then global. `get/3` resolves scope identically.
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

  Checks local scope first (by `scope_hint` if provided, otherwise `self()`),
  then global — the same resolution `member?/4` performs.
  """
  @spec get(GenServer.server(), String.t(), keyword()) :: term() | nil
  def get(store, name, opts \\ []) do
    scope_hint = Keyword.get(opts, :scope_hint, self())
    GenServer.call(store, {:get, name, scope_hint})
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
    {:reply, :ok, demonitor_if_unused(%{state | entries: entries}, scope_tag)}
  end

  def handle_call({:drop_scope, scope_tag}, _from, state) do
    entries =
      state.entries
      |> Enum.reject(fn {{_name, tag}, _entry} -> tag == scope_tag end)
      |> Map.new()

    {:reply, :ok, demonitor_if_unused(%{state | entries: entries}, scope_tag)}
  end

  def handle_call({:member?, name, discriminator, value}, _from, state) do
    result =
      case resolve_entry(state.entries, name, discriminator) do
        nil -> false
        entry -> dataset_member?(entry.dataset, value)
      end

    {:reply, result, state}
  end

  def handle_call({:member_any?, names, discriminator, value}, _from, state) do
    result =
      Enum.any?(names, fn name ->
        case resolve_entry(state.entries, name, discriminator) do
          nil -> false
          entry -> dataset_member?(entry.dataset, value)
        end
      end)

    {:reply, result, state}
  end

  def handle_call({:get, name, discriminator}, _from, state) do
    result =
      case resolve_entry(state.entries, name, discriminator) do
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
  #
  # A non-pid discriminator is deliberately not monitored: there is no
  # process behind a rule name to watch. That is not an oversight to be
  # fixed here but the reason `drop_scope/2` exists — see the moduledoc.
  defp maybe_monitor({:local, pid}, monitors) when is_pid(pid) do
    if Map.has_key?(monitors, pid) do
      monitors
    else
      ref = Process.monitor(pid)
      Map.put(monitors, pid, ref)
    end
  end

  defp maybe_monitor({:local, _discriminator}, monitors), do: monitors
  defp maybe_monitor(:global, monitors), do: monitors

  # Drops the monitor for a pid scope once nothing is registered under it.
  # Without this, the monitors map is a second leak: monitors accumulate for
  # pids whose entries have all been removed, and the store keeps a link to
  # a process it no longer holds anything for.
  defp demonitor_if_unused(state, {:local, pid}) when is_pid(pid) do
    still_used? = Enum.any?(state.entries, fn {{_n, tag}, _e} -> tag == {:local, pid} end)

    case {still_used?, Map.fetch(state.monitors, pid)} do
      {false, {:ok, ref}} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: Map.delete(state.monitors, pid)}

      _ ->
        state
    end
  end

  defp demonitor_if_unused(state, _scope_tag), do: state

  # Resolve by checking local scope first, then global.
  defp resolve_entry(entries, name, discriminator) do
    case Map.fetch(entries, {name, {:local, discriminator}}) do
      {:ok, entry} ->
        entry

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

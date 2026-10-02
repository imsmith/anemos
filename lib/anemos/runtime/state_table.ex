defmodule Anemos.Runtime.StateTable do
  @moduledoc """
  Where a runtime keeps what its processes have accumulated, so that the
  restart of one of them does not lose it.

  `Anemos.Runtime.PolicyStore` holds what was *loaded*. This holds what has
  *happened* since: `set` bindings and armed dwell timers (A-40, A-41), each
  condition's boolean (A-42), and the module registrations (A-43).

  It is an ETS table owned by the runtime's supervisor process. Every child
  that writes to it can crash and be restarted without the table going
  anywhere; it dies only with the runtime itself. A process could not do
  this job: the module registry is already a process, and a second one
  behind it would just move the question.

  The table is public, because its writers are the supervisor's children.
  That grants nothing new — everything in it was already reachable by
  calling the process that held it, under a name just as public.

  Every function accepts `nil` for the table and does nothing, so a
  dispatcher, registry or condition server started on its own, outside an
  `Anemos.Runtime`, works as before and simply keeps no durable state.

  It does not survive the node. Persisting it to disk is a separate
  decision — a `set` binding can hold an `Anemos.Secret`.
  """

  @type t :: :ets.table() | nil

  @doc "Creates the table. Call from the process that should own it."
  @spec new(atom()) :: :ets.table()
  def new(runtime), do: :ets.new(name_for(runtime), [:set, :public, :named_table])

  @doc "The table of the runtime `runtime`."
  @spec name_for(atom()) :: atom()
  def name_for(runtime), do: :"#{runtime}.state"

  @doc """
  Appends `entry` to the bounded log `kind`, dropping the oldest once there
  are more than `limit`.
  """
  @spec push(t(), atom(), term(), pos_integer()) :: :ok
  def push(nil, _kind, _entry, _limit), do: :ok

  def push(table, kind, entry, limit) do
    n = :ets.update_counter(table, {kind, :seq}, 1, {{kind, :seq}, 0})
    true = :ets.insert(table, {{kind, n}, entry})
    true = :ets.delete(table, {kind, n - limit})
    :ok
  end

  @doc "The newest `limit` entries of the log `kind`, newest first."
  @spec recent(t(), atom(), pos_integer()) :: [term()]
  def recent(nil, _kind, _limit), do: []

  def recent(table, kind, limit) do
    # A runtime that is not running has no table, and nothing to report.
    if :ets.whereis(table) == :undefined do
      []
    else
      newest = get(table, {kind, :seq}, 0)

      for n <- newest..max(newest - limit + 1, 1)//-1,
          [{_key, entry}] <- [:ets.lookup(table, {kind, n})],
          do: entry
    end
  end

  @spec put(t(), term(), term()) :: :ok
  def put(nil, _key, _value), do: :ok

  def put(table, key, value) do
    true = :ets.insert(table, {key, value})
    :ok
  end

  @spec get(t(), term(), term()) :: term()
  def get(nil, _key, default), do: default

  def get(table, key, default) do
    case :ets.lookup(table, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end

  @spec delete(t(), term()) :: :ok
  def delete(nil, _key), do: :ok

  def delete(table, key) do
    true = :ets.delete(table, key)
    :ok
  end
end

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
  def new(runtime), do: :ets.new(:"#{runtime}.state", [:set, :public])

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

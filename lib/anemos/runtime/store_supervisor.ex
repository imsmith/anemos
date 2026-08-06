defmodule Anemos.Runtime.StoreSupervisor do
  @moduledoc """
  Supervisor for stores-as-infrastructure.

  Owns every process the dispatcher reads from or writes to but does not
  itself represent: the `TripleStore`, the `DataStore`, the
  `SubscribableRegistry`, and one `ConditionServer` / `CapabilityServer`
  per declaration in the loaded policy set.

  These processes were previously `start_link`ed from inside
  `Anemos.Runtime.Dispatcher.init/1`. Because the dispatcher does not trap
  exits, the death of any one of them killed the dispatcher, and the
  dispatcher's own restart came back with an empty rule set — silently
  destroying every loaded policy. Re-parenting them here severs that link:
  a store crash is now a local, recoverable event.

  ## Resolution, not caching

  Children are addressed by supervisor child id, never by cached pid:

    * `:triple_store`, `:data_store`, `:subscribable_registry`
    * `{:condition, name}`, `{:capability, name}`

  `whereis/2` and `snapshot/1` read the live child list, so a restarted
  child is picked up on the next dispatch rather than leaving the caller
  holding a dead pid. The cost is one supervisor call per dispatch cycle,
  which is cheap next to the rule bodies it precedes.

  ## Restart strategy

  `:one_for_one` — the children are mutually independent. A `TripleStore`
  crash tells you nothing about the `DataStore`, and restarting healthy
  stores would discard state for no reason.

  Every child is `:permanent`. All of them are infrastructure the runtime
  needs in order to interpret a policy at all; none has a "finished
  normally" state. Restarted stores come back empty, which is the correct
  safe default: a condition that has lost its history reads `false`, and a
  data block that has lost its dataset reports no members.
  """

  use Supervisor

  alias Anemos.Runtime.{CapabilityServer, ConditionServer, DataStore, SubscribableRegistry, TripleStore}

  @doc """
  Starts the store supervisor.

  ## Options

    * `:name` — process registration name (optional)
  """
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(_opts) do
    children = [
      Supervisor.child_spec({TripleStore, []}, id: :triple_store, restart: :permanent),
      Supervisor.child_spec({DataStore, []}, id: :data_store, restart: :permanent),
      Supervisor.child_spec({SubscribableRegistry, []},
        id: :subscribable_registry,
        restart: :permanent
      )
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Resolution ---

  @doc """
  Returns the live pid for a child id, or `nil` if it is absent or restarting.
  """
  @spec whereis(Supervisor.supervisor(), term()) :: pid() | nil
  def whereis(sup, id) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _type, _mods} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  @doc """
  Reads the whole child list in one call and shapes it for the dispatcher.

  Returns `%{triple_store: pid, data_store: pid, subscribable_registry: pid,
  conditions: %{name => pid}, capabilities: %{name => pid}}`. Any child that
  is mid-restart appears as `nil` (infrastructure) or is simply absent from
  the maps.
  """
  @spec snapshot(Supervisor.supervisor()) :: map()
  def snapshot(sup) do
    empty = %{
      triple_store: nil,
      data_store: nil,
      subscribable_registry: nil,
      conditions: %{},
      capabilities: %{}
    }

    sup
    |> Supervisor.which_children()
    |> Enum.reduce(empty, fn
      {_id, pid, _t, _m}, acc when not is_pid(pid) -> acc
      {:triple_store, pid, _t, _m}, acc -> %{acc | triple_store: pid}
      {:data_store, pid, _t, _m}, acc -> %{acc | data_store: pid}
      {:subscribable_registry, pid, _t, _m}, acc -> %{acc | subscribable_registry: pid}
      {{:condition, name}, pid, _t, _m}, acc -> %{acc | conditions: Map.put(acc.conditions, name, pid)}
      {{:capability, name}, pid, _t, _m}, acc -> %{acc | capabilities: Map.put(acc.capabilities, name, pid)}
      _other, acc -> acc
    end)
  end

  # --- Dynamic policy-derived children ---

  @doc """
  Starts (or replaces) the condition server for a compiled condition.

  Replacement rather than reuse is deliberate: `on_transition` closes over
  the dispatcher pid, so a dispatcher that has just restarted must install
  callbacks pointing at itself. The condition's boolean state resets to
  `false` in the process, which is the safe reading.

  `on_side_effects` is the second such callback, and it exists for the same
  reason `on_transition` does: the condition server can compute a body's
  operations but cannot execute one — routing an `emit` or a `[MOD::verb]`
  is the dispatcher's job. Omitting it leaves the operations dropped, which
  is what A-50 was.
  """
  @spec put_condition(
          Supervisor.supervisor(),
          map(),
          (String.t() -> any()),
          (String.t(), [map()] -> any()) | nil
        ) :: {:ok, pid()} | {:error, term()}
  def put_condition(sup, cond_spec, on_transition, on_side_effects \\ nil) do
    args = [
      name_str: cond_spec.name,
      subscriptions: cond_spec.subscriptions,
      evaluator: cond_spec.evaluator,
      side_effects: Map.get(cond_spec, :side_effects, []),
      side_effect_handler: Map.get(cond_spec, :side_effect_handler),
      on_side_effects: on_side_effects,
      on_transition: on_transition
    ]

    replace_child(sup, %{
      id: {:condition, cond_spec.name},
      start: {ConditionServer, :start_link, [args]},
      restart: :permanent,
      type: :worker
    })
  end

  @doc """
  Starts (or replaces) the capability server for a compiled capability.
  """
  @spec put_capability(Supervisor.supervisor(), map()) :: {:ok, pid()} | {:error, term()}
  def put_capability(sup, cap) do
    args = [
      name_str: cap.name,
      context: cap.context || "",
      handler: cap.handler
    ]

    replace_child(sup, %{
      id: {:capability, cap.name},
      start: {CapabilityServer, :start_link, [args]},
      restart: :permanent,
      type: :worker
    })
  end

  defp replace_child(sup, %{id: id} = child_spec) do
    _ = Supervisor.terminate_child(sup, id)
    _ = Supervisor.delete_child(sup, id)

    case Supervisor.start_child(sup, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end
end

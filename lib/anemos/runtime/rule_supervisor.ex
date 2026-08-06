defmodule Anemos.Runtime.RuleSupervisor do
  @moduledoc """
  Second supervision tier: rule-scoped processes.

  `Anemos.Runtime.StoreSupervisor` holds everything whose lifetime is the
  runtime's. This supervisor holds everything whose lifetime is a *rule's*.
  The distinction matters on failure: a rule-scoped store that dies should
  take down that rule's scope and nothing else, whereas a shared store
  coming back empty affects every rule at once.

  ## What actually runs here

  Nothing, until a rule needs it.

  `ensure_scope/2` starts a child `Supervisor` for one named rule and
  returns its pid; a second call for the same rule returns the same pid
  without starting anything. Rules that consume only shared infrastructure
  — which, in the current interpreter, is all of them — never cause a child
  to be started. `scope/2` returns `nil` for such a rule rather than
  creating one on read.

  This replaces the previous moduledoc claim that the module was "ready to
  supervise per-rule GenServers": it was an empty `DynamicSupervisor` that
  nothing started children in and nothing resolved children from.

  ## Restart strategy

  `:one_for_one` at this tier — rule scopes are independent of one another,
  and one policy's failure must not restart another policy's state.

  Each per-rule scope is `:transient`: it is restarted if it crashes, but a
  scope that is deliberately torn down by `stop_scope/2` (policy unloaded)
  stays down.
  """

  use DynamicSupervisor

  @doc """
  Starts the rule supervisor.

  ## Options

    * `:name` — process registration name (defaults to `__MODULE__`)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Returns the scope supervisor for `rule_name`, starting it if absent.

  The returned pid is a plain `Supervisor` with no children; rule-scoped
  stores are added to it with `Supervisor.start_child/2`.
  """
  @spec ensure_scope(DynamicSupervisor.supervisor(), String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_scope(sup, rule_name) do
    case scope(sup, rule_name) do
      nil ->
        spec = %{
          id: {:rule_scope, rule_name},
          start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
          restart: :transient,
          type: :supervisor
        }

        case DynamicSupervisor.start_child(sup, spec) do
          {:ok, pid} -> {:ok, tag(pid, rule_name)}
          {:ok, pid, _info} -> {:ok, tag(pid, rule_name)}
          {:error, reason} -> {:error, reason}
        end

      pid ->
        {:ok, pid}
    end
  end

  @doc """
  Returns the scope supervisor for `rule_name`, or `nil` if the rule has
  never needed one. Never starts anything.
  """
  @spec scope(DynamicSupervisor.supervisor(), String.t()) :: pid() | nil
  def scope(sup, rule_name) do
    Enum.find_value(scopes(sup), fn {name, pid} -> name == rule_name && pid end)
  end

  @doc """
  Returns `[{rule_name, pid}]` for every live rule scope.
  """
  @spec scopes(DynamicSupervisor.supervisor()) :: [{String.t(), pid()}]
  def scopes(sup) do
    for {_id, pid, _type, _mods} <- DynamicSupervisor.which_children(sup),
        is_pid(pid),
        name = :persistent_term.get({__MODULE__, pid}, nil),
        not is_nil(name) do
      {name, pid}
    end
  end

  @doc """
  Tears down a rule's scope and everything in it. Idempotent.
  """
  @spec stop_scope(DynamicSupervisor.supervisor(), String.t()) :: :ok
  def stop_scope(sup, rule_name) do
    case scope(sup, rule_name) do
      nil ->
        :ok

      pid ->
        :persistent_term.erase({__MODULE__, pid})
        _ = DynamicSupervisor.terminate_child(sup, pid)
        :ok
    end
  end

  # DynamicSupervisor discards child ids, so the rule name a scope belongs to
  # has to be recorded outside the supervisor. Scopes are created once per
  # rule and rarely, which is exactly the read-heavy/write-rare shape
  # :persistent_term is for.
  defp tag(pid, rule_name) do
    :persistent_term.put({__MODULE__, pid}, rule_name)
    pid
  end
end

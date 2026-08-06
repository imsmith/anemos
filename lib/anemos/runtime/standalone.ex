defmodule Anemos.Runtime.Standalone do
  @moduledoc """
  Wires a dispatcher and its stores together outside a full `Anemos.Runtime`
  tree.

  `Anemos.Runtime.Dispatcher` deliberately starts nothing: its stores belong
  to `Anemos.Runtime.StoreSupervisor` and its policy set to
  `Anemos.Runtime.PolicyStore`. That is the right shape for a supervised
  runtime, but it makes the one-shot case — `Anemos.run/2`, and tests that
  want a dispatcher and nothing else — a three-step dance. This module is
  that dance, in one call.

  Everything it starts is linked to the caller, so a test process exiting
  takes the whole set with it. `stop/1` tears the set down explicitly for
  callers that outlive it — without which `Anemos.run/2` leaked its stores
  on every invocation, since `GenServer.stop/1` exits `:normal` and
  non-trapping linked processes ignore that signal.
  """

  alias Anemos.Runtime.{Dispatcher, PolicyStore, StoreSupervisor, SubscribableRegistry}

  @doc """
  Starts a policy store, a store supervisor and a dispatcher, and returns
  the dispatcher.

  ## Options

    * `:registry` — pid or name of a `ModuleRegistry` (required)
    * `:rules`, `:conditions`, `:capabilities`, `:data_blocks` — seeded into
      the policy store before the dispatcher starts, so a dispatcher restart
      rebuilds them (all optional)
    * `:channel_connector` — recorded in the policy store (optional)
    * `:subscribable_registry` — an existing registry whose contents are
      copied into the supervised one (optional)
    * `:name` — dispatcher registration name (optional)
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    with {:ok, policy_store} <- PolicyStore.start_link([]),
         {:ok, store_sup} <- StoreSupervisor.start_link([]) do
      seed_connector(policy_store, opts)
      seed_subscribables(store_sup, opts)
      seed_policy(policy_store, opts)

      Dispatcher.start_link(
        registry: Keyword.fetch!(opts, :registry),
        policy_store: policy_store,
        store_supervisor: store_sup,
        rule_supervisor: Keyword.get(opts, :rule_supervisor),
        name: Keyword.get(opts, :name)
      )
    end
  end

  @doc """
  Stops a dispatcher started by `start_link/1` and everything under it.
  """
  @spec stop(pid() | atom()) :: :ok
  def stop(dispatcher) do
    %{store_supervisor: store_sup, policy_store: policy_store} = Dispatcher.topology(dispatcher)
    stop_quietly(dispatcher, &GenServer.stop/1)
    stop_quietly(store_sup, &Supervisor.stop/1)
    stop_quietly(policy_store, &Agent.stop/1)
    :ok
  end

  defp stop_quietly(pid, stopper) do
    if is_pid(pid) and Process.alive?(pid), do: stopper.(pid)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp seed_connector(policy_store, opts) do
    case Keyword.get(opts, :channel_connector) do
      nil -> :ok
      connector -> PolicyStore.put_connector(policy_store, connector)
    end
  end

  # A caller-supplied registry cannot be adopted into the supervisor without
  # making the supervisor responsible for a process it did not start, so its
  # registrations are copied into the supervised one instead.
  defp seed_subscribables(store_sup, opts) do
    case Keyword.get(opts, :subscribable_registry) do
      nil ->
        :ok

      external ->
        target = StoreSupervisor.whereis(store_sup, :subscribable_registry)

        Enum.each(SubscribableRegistry.list(external), fn protocol ->
          case SubscribableRegistry.lookup(external, protocol) do
            {:ok, handler} -> SubscribableRegistry.register(target, protocol, handler)
            :error -> :ok
          end
        end)
    end
  end

  defp seed_policy(policy_store, opts) do
    compiled = %Anemos.CompilationResult{
      rules: Keyword.get(opts, :rules, []),
      conditions: Keyword.get(opts, :conditions, []),
      capabilities: Keyword.get(opts, :capabilities, []),
      data_blocks: Keyword.get(opts, :data_blocks, [])
    }

    PolicyStore.put(policy_store, compiled)
  end
end

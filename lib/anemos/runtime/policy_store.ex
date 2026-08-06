defmodule Anemos.Runtime.PolicyStore do
  @moduledoc """
  Durable record of everything that has been loaded into a runtime.

  The dispatcher holds a *derived* view — a rule index, a set of condition
  servers, a set of capability servers. That view is disposable. This store
  holds the source it is derived from, so that a dispatcher which crashes
  and is restarted by its supervisor can rebuild rather than come back
  blank.

  Without it, re-parenting the dispatcher's children (see
  `Anemos.Runtime.StoreSupervisor`) only narrows the window: any *other*
  dispatcher crash still produced a restarted dispatcher with `rules: []`,
  and `dispatch/3` then returned `{:ok, []}` forever — byte-identical to
  "no rule matched".

  It also holds the channel connector, which is set through the dispatcher
  at runtime and would otherwise silently revert to the default on restart.
  """

  use Agent

  @doc """
  Starts a policy store.

  ## Options

    * `:name` — process registration name (optional)
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    initial = %{policies: [], connector: Anemos.Channel.Logger}
    Agent.start_link(fn -> initial end, name: Keyword.get(opts, :name))
  end

  @doc """
  Appends a compilation result. Load order is preserved — rebuilding replays
  it, so later policies shadow earlier ones exactly as they did on first load.
  """
  @spec put(Agent.agent(), Anemos.CompilationResult.t()) :: :ok
  def put(store, %Anemos.CompilationResult{} = compiled) do
    Agent.update(store, fn s -> %{s | policies: s.policies ++ [compiled]} end)
  end

  @doc """
  Removes the named rules from every stored compilation result.

  This is what makes `Anemos.Runtime.Dispatcher.unload/2` durable. The
  dispatcher's rule list is derived and rebuilt from this store on restart,
  so an unload that touched only the derived view would be undone by the
  next dispatcher crash — the rule would come back.

  Only rules are removed. A compilation result also carries conditions,
  capabilities and data blocks, which are not owned by any one rule and are
  not implied by unloading one. A result left with no rules is kept for the
  same reason.
  """
  @spec drop_rules(Agent.agent(), [String.t()]) :: :ok
  def drop_rules(store, rule_names) do
    drop = MapSet.new(rule_names)

    Agent.update(store, fn s ->
      policies =
        Enum.map(s.policies, fn compiled ->
          %{compiled | rules: Enum.reject(compiled.rules, &MapSet.member?(drop, &1.name))}
        end)

      %{s | policies: policies}
    end)
  end

  @doc """
  Returns every loaded compilation result in load order.
  """
  @spec all(Agent.agent()) :: [Anemos.CompilationResult.t()]
  def all(store), do: Agent.get(store, & &1.policies)

  @doc """
  Records the channel connector so it survives a dispatcher restart.
  """
  @spec put_connector(Agent.agent(), module()) :: :ok
  def put_connector(store, connector) do
    Agent.update(store, fn s -> %{s | connector: connector} end)
  end

  @doc """
  Returns the recorded channel connector.
  """
  @spec connector(Agent.agent()) :: module()
  def connector(store), do: Agent.get(store, & &1.connector)
end

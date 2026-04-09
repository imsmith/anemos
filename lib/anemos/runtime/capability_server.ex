defmodule Anemos.Runtime.CapabilityServer do
  @moduledoc """
  GenServer for a single named capability.
  Passive until demanded. Executes its `on demand` handler and returns the result.
  """

  use GenServer

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec execute(pid() | atom(), map()) :: {:ok, list()} | {:error, term()}
  def execute(server, context), do: GenServer.call(server, {:execute, context})

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name_str),
      context: Keyword.fetch!(opts, :context),
      handler: Keyword.fetch!(opts, :handler)
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:execute, context}, _from, state) do
    result =
      try do
        state.handler.(context)
      rescue
        e in [RuntimeError, ArgumentError, FunctionClauseError, KeyError] ->
          {:error, {:capability_crash, state.name, Exception.message(e)}}
      end
    {:reply, result, state}
  end
end

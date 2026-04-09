defmodule Anemos.Runtime.ConditionServer do
  @moduledoc """
  GenServer for a single named condition.
  Holds boolean state. Evaluates incoming events against trigger logic.
  Broadcasts `CONDITION_<name>` on false->true transition.
  Queryable for current state at any time.
  """

  use GenServer

  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_state(pid() | atom()) :: boolean()
  def get_state(server), do: GenServer.call(server, :get_state)

  @spec handle_event(pid() | atom(), String.t(), map()) :: :ok
  def handle_event(server, event_name, context), do: GenServer.cast(server, {:event, event_name, context})

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name_str),
      subscriptions: MapSet.new(Keyword.fetch!(opts, :subscriptions)),
      evaluator: Keyword.fetch!(opts, :evaluator),
      side_effects: Keyword.get(opts, :side_effects, []),
      on_transition: Keyword.get(opts, :on_transition),
      value: false
    }
    {:ok, state}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.value, state}

  @impl true
  def handle_cast({:event, event_name, context}, state) do
    if MapSet.member?(state.subscriptions, event_name) do
      new_value = state.evaluator.(event_name, context)
      case {state.value, new_value} do
        {false, true} ->
          if state.on_transition, do: state.on_transition.(state.name)
          {:noreply, %{state | value: true}}
        {_old, new_val} ->
          {:noreply, %{state | value: new_val}}
      end
    else
      {:noreply, state}
    end
  end
end

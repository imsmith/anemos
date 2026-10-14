defmodule Anemos.Runtime.ConditionServer do
  @moduledoc """
  GenServer for a single named condition.
  Holds boolean state. Evaluates incoming events against trigger logic.
  Broadcasts `CONDITION_<name>` on false->true transition.
  Queryable for current state at any time.

  On a false->true transition the condition body's side effects run and yield a
  list of operations. Those operations only go somewhere if an `:on_side_effects`
  callback was supplied — nothing here can execute a `:command` or route an
  `:emit`, which is the dispatcher's job. Without the callback they are dropped.
  """

  use GenServer

  alias Anemos.Runtime.{Report, StateTable}

  @doc """
  Starts a condition server.

  ## Options

    * `:name_str` — the condition name (required)
    * `:subscriptions` — list of event names this condition listens to (required)
    * `:evaluator` — 2-arity function `(event_name, context) -> boolean` (required)
    * `:side_effects` — AST nodes to evaluate on transition (optional)
    * `:side_effect_handler` — function called on false->true (optional). The
      compiler produces a 1-arity function taking the triggering event context;
      a 0-arity function is also accepted.
    * `:on_side_effects` — callback `(name, [operation]) -> any` receiving the
      operations the side-effect handler produced (optional). Without it the
      operations are discarded — see the moduledoc.
    * `:on_transition` — callback `(name) -> any` called on false->true (optional)
    * `:name` — process registration name (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Returns the current boolean state of the condition.

  ## Examples

      iex> {:ok, pid} = Anemos.Runtime.ConditionServer.start_link(name_str: "test", subscriptions: ["EV"], evaluator: fn _, _ -> true end)
      iex> Anemos.Runtime.ConditionServer.get_state(pid)
      false

  """
  @spec get_state(pid() | atom()) :: boolean()
  def get_state(server), do: GenServer.call(server, :get_state)

  @doc """
  Sends an event to the condition server for evaluation.

  If the event matches a subscription and the evaluator returns `true`,
  the condition transitions to true. Only false->true transitions trigger
  the `on_transition` callback.
  """
  @spec handle_event(pid() | atom(), String.t(), map()) :: :ok
  def handle_event(server, event_name, context),
    do: GenServer.cast(server, {:event, event_name, context})

  @impl true
  def init(opts) do
    state = %{
      name: Keyword.fetch!(opts, :name_str),
      subscriptions: MapSet.new(Keyword.fetch!(opts, :subscriptions)),
      evaluator: Keyword.fetch!(opts, :evaluator),
      side_effects: Keyword.get(opts, :side_effects, []),
      side_effect_handler: Keyword.get(opts, :side_effect_handler),
      on_side_effects: Keyword.get(opts, :on_side_effects),
      on_transition: Keyword.get(opts, :on_transition),
      state_table: Keyword.get(opts, :state_table)
    }

    # A-42. A condition that was true before this process was replaced — by
    # a dispatcher restart, or by its own crash — is still true. Coming back
    # false would make the next true evaluation a transition, and fire every
    # CONDITION_<name> rule a second time.
    value = StateTable.get(state.state_table, {:condition, state.name}, false)

    # A-47. The last report of each event heard, which a compound trigger is
    # decided over. Kept across a restart for the same reason the value is.
    reports = StateTable.get(state.state_table, {:condition_reports, state.name}, %{})
    {:ok, state |> Map.put(:value, value) |> Map.put(:reports, reports)}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state.value, state}

  @impl true
  def handle_cast({:event, event_name, context}, state) do
    if MapSet.member?(state.subscriptions, event_name) do
      # The report is written down before anything is decided, so every
      # operand's state is recorded whatever the others say.
      reports = Map.put(state.reports, event_name, Report.truthy?(context))
      :ok = StateTable.put(state.state_table, {:condition_reports, state.name}, reports)
      state = %{state | reports: reports}
      new_value = state.evaluator.(event_name, Map.put(context, :_reports, reports))

      case {state.value, new_value} do
        {false, true} ->
          run_side_effects(state, context)
          if state.on_transition, do: state.on_transition.(state.name)
          {:noreply, remember(state, true)}

        {_old, new_val} ->
          {:noreply, remember(state, new_val)}
      end
    else
      {:noreply, state}
    end
  end

  defp remember(%{value: value} = state, value), do: state

  defp remember(state, value) do
    :ok = StateTable.put(state.state_table, {:condition, state.name}, value)
    %{state | value: value}
  end

  defp run_side_effects(%{side_effect_handler: nil}, _context), do: :ok

  defp run_side_effects(state, context) do
    handler = state.side_effect_handler

    result =
      if is_function(handler, 1), do: handler.(context), else: handler.()

    case {result, state.on_side_effects} do
      {{:ok, ops}, callback} when is_function(callback, 2) -> callback.(state.name, ops)
      _ -> :ok
    end
  end
end

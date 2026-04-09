defmodule Anemos.Runtime.Scheduler do
  @moduledoc """
  GenServer that manages time-triggered schedules.

  Holds compiled `at` specs, manages timers via `Process.send_after/3` and
  `:timer.send_interval/2`, and dispatches synthetic `AT_*` events into the
  runtime when timers fire.
  """

  use GenServer

  @doc """
  Starts the scheduler.

  ## Options

    * `:name` — process registration name (optional)
    * `:runtime_name` — the Anemos.Runtime name for dispatching events (required)
    * `:dispatch_fn` — override dispatch function for testing (optional)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds schedule specs to the running scheduler. Timers start immediately.
  """
  @spec schedule(pid() | atom(), [Anemos.CompiledSchedule.t()]) :: :ok
  def schedule(server, schedules) do
    GenServer.call(server, {:schedule, schedules})
  end

  @impl true
  def init(opts) do
    runtime_name = Keyword.fetch!(opts, :runtime_name)
    dispatch_fn = Keyword.get(opts, :dispatch_fn)

    {:ok, %{
      runtime_name: runtime_name,
      dispatch_fn: dispatch_fn,
      timers: %{},
      schedules: []
    }}
  end

  @impl true
  def handle_call({:schedule, new_schedules}, _from, state) do
    new_timers =
      Enum.reduce(new_schedules, state.timers, fn sched, timers ->
        timer_ref = start_timer(sched)
        Map.put(timers, sched.event_name, {timer_ref, sched})
      end)

    {:reply, :ok, %{state |
      schedules: state.schedules ++ new_schedules,
      timers: new_timers
    }}
  end

  @impl true
  def handle_info({:fire, event_name}, state) do
    do_dispatch(event_name, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:fire_recurring, event_name, sched}, state) do
    do_dispatch(event_name, state)
    timer_ref = schedule_next_occurrence(sched)
    new_timers = Map.put(state.timers, event_name, {timer_ref, sched})
    {:noreply, %{state | timers: new_timers}}
  end

  defp do_dispatch(event_name, state) do
    if state.dispatch_fn do
      state.dispatch_fn.(event_name, %{})
    else
      Anemos.Runtime.dispatch(state.runtime_name, event_name)
    end
  end

  defp start_timer(%{time_spec: {:interval, dur}, event_name: name, recurrence: :interval}) do
    ms = duration_to_ms(dur)
    {:ok, ref} = :timer.send_interval(ms, {:fire, name})
    ref
  end

  defp start_timer(%{time_spec: {:delay_ms, ms}, event_name: name, recurrence: nil}) do
    Process.send_after(self(), {:fire, name}, ms)
  end

  defp start_timer(%{time_spec: {:time, {h, m}}, event_name: name, recurrence: nil}) do
    ms = ms_until_time(h, m)
    Process.send_after(self(), {:fire, name}, ms)
  end

  defp start_timer(%{time_spec: {:time, {h, m}}, recurrence: recurrence} = sched)
       when recurrence != nil do
    ms = ms_until_next_occurrence(h, m, recurrence)
    Process.send_after(self(), {:fire_recurring, sched.event_name, sched}, ms)
  end

  defp start_timer(%{time_spec: {:date, {y, mo, d}}, event_name: name, recurrence: nil}) do
    ms = ms_until_date(y, mo, d)
    if ms > 0, do: Process.send_after(self(), {:fire, name}, ms)
  end

  defp start_timer(%{time_spec: {:day, day}, event_name: name, recurrence: nil}) do
    ms = ms_until_day(day)
    Process.send_after(self(), {:fire, name}, ms)
  end

  defp schedule_next_occurrence(%{time_spec: {:time, {h, m}}, recurrence: recurrence} = sched) do
    ms = ms_until_next_occurrence(h, m, recurrence)
    Process.send_after(self(), {:fire_recurring, sched.event_name, sched}, ms)
  end

  # --- Time calculations ---

  defp duration_to_ms({amount, :ms}), do: amount
  defp duration_to_ms({amount, :s}), do: amount * 1_000
  defp duration_to_ms({amount, :seconds}), do: amount * 1_000
  defp duration_to_ms({amount, :min}), do: amount * 60_000
  defp duration_to_ms({amount, :minutes}), do: amount * 60_000
  defp duration_to_ms({amount, :h}), do: amount * 3_600_000
  defp duration_to_ms({amount, :hours}), do: amount * 3_600_000
  defp duration_to_ms({amount, :d}), do: amount * 86_400_000
  defp duration_to_ms({amount, :days}), do: amount * 86_400_000

  defp ms_until_time(hour, minute) do
    now = NaiveDateTime.local_now()
    target = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(hour, minute, 0))
    target = if NaiveDateTime.compare(target, now) != :gt do
      NaiveDateTime.add(target, 86_400, :second)
    else
      target
    end
    NaiveDateTime.diff(target, now, :millisecond)
  end

  defp ms_until_date(year, month, day) do
    now = NaiveDateTime.local_now()
    target = NaiveDateTime.new!(Date.new!(year, month, day), Time.new!(0, 0, 1))
    NaiveDateTime.diff(target, now, :millisecond)
  end

  defp ms_until_day(target_day) do
    now = NaiveDateTime.local_now()
    today = Date.day_of_week(NaiveDateTime.to_date(now))
    target_num = day_to_number(target_day)
    days_ahead = rem(target_num - today + 7, 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    target_date = Date.add(NaiveDateTime.to_date(now), days_ahead)
    target = NaiveDateTime.new!(target_date, Time.new!(0, 0, 1))
    NaiveDateTime.diff(target, now, :millisecond)
  end

  defp ms_until_next_occurrence(hour, minute, :day), do: ms_until_time(hour, minute)

  defp ms_until_next_occurrence(hour, minute, :weekday) do
    now = NaiveDateTime.local_now()
    today = Date.day_of_week(NaiveDateTime.to_date(now))
    target_today = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(hour, minute, 0))

    cond do
      today in 1..5 and NaiveDateTime.compare(target_today, now) == :gt ->
        NaiveDateTime.diff(target_today, now, :millisecond)
      today in 1..4 ->
        target = NaiveDateTime.add(target_today, 86_400, :second)
        NaiveDateTime.diff(target, now, :millisecond)
      true ->
        days_to_monday = rem(8 - today, 7)
        days_to_monday = if days_to_monday == 0, do: 7, else: days_to_monday
        target = NaiveDateTime.new!(Date.add(NaiveDateTime.to_date(now), days_to_monday), Time.new!(hour, minute, 0))
        NaiveDateTime.diff(target, now, :millisecond)
    end
  end

  defp ms_until_next_occurrence(hour, minute, :weekend) do
    now = NaiveDateTime.local_now()
    today = Date.day_of_week(NaiveDateTime.to_date(now))
    target_today = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(hour, minute, 0))

    cond do
      today in [6, 7] and NaiveDateTime.compare(target_today, now) == :gt ->
        NaiveDateTime.diff(target_today, now, :millisecond)
      today == 6 ->
        target = NaiveDateTime.add(target_today, 86_400, :second)
        NaiveDateTime.diff(target, now, :millisecond)
      true ->
        days_to_saturday = rem(6 - today + 7, 7)
        days_to_saturday = if days_to_saturday == 0, do: 7, else: days_to_saturday
        target = NaiveDateTime.new!(Date.add(NaiveDateTime.to_date(now), days_to_saturday), Time.new!(hour, minute, 0))
        NaiveDateTime.diff(target, now, :millisecond)
    end
  end

  defp ms_until_next_occurrence(hour, minute, day_atom) do
    now = NaiveDateTime.local_now()
    today = Date.day_of_week(NaiveDateTime.to_date(now))
    target_num = day_to_number(day_atom)
    target_today = NaiveDateTime.new!(NaiveDateTime.to_date(now), Time.new!(hour, minute, 0))
    days_ahead = rem(target_num - today + 7, 7)

    if days_ahead == 0 and NaiveDateTime.compare(target_today, now) == :gt do
      NaiveDateTime.diff(target_today, now, :millisecond)
    else
      days_ahead = if days_ahead == 0, do: 7, else: days_ahead
      target = NaiveDateTime.new!(Date.add(NaiveDateTime.to_date(now), days_ahead), Time.new!(hour, minute, 0))
      NaiveDateTime.diff(target, now, :millisecond)
    end
  end

  defp day_to_number(:monday), do: 1
  defp day_to_number(:tuesday), do: 2
  defp day_to_number(:wednesday), do: 3
  defp day_to_number(:thursday), do: 4
  defp day_to_number(:friday), do: 5
  defp day_to_number(:saturday), do: 6
  defp day_to_number(:sunday), do: 7
end

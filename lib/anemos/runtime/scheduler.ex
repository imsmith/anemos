defmodule Anemos.Runtime.Scheduler do
  @moduledoc """
  GenServer that manages time-triggered schedules.

  Holds compiled `at` specs, manages timers via `Process.send_after/3` and
  `:timer.send_interval/2`, and dispatches synthetic `AT_*` events into the
  runtime when timers fire.

  ## Resource limits

  Schedule specs come from policy text, which is not necessarily trusted.
  Two limits bound what a policy can cost the runtime:

    * **Interval floor** (`:min_interval_ms`, default 1000). Every firing of
      an interval schedule becomes a synchronous dispatch through a single
      dispatcher process, so a `1ms` interval is a 1000 Hz loop that starves
      every other rule. Intervals below the floor are **rejected, not
      clamped**: silently running a schedule at a rate the policy did not ask
      for makes the runtime's behaviour diverge from its policy text with
      nothing to observe. Rejection tells the author their schedule is
      unrunnable; clamping does not.

    * **Schedule cap** (`:max_schedules`, default 1000) on the number of
      armed timers per scheduler, enforced cumulatively across calls.

  Both default from application env (`:anemos`, `:min_schedule_interval_ms`
  and `:max_schedules`) and may be overridden per scheduler at `start_link/1`.

  ## Schedules that cannot be armed

  A past-dated schedule, an unresolvable natural-language date, or an
  unrecognised duration unit yields a schedule that will never fire. These do
  not report `:ok` — `schedule/2` returns `{:error, failures}` and logs a
  warning for each. Arming is otherwise best-effort per spec: one bad entry
  does not prevent the rest of the batch from being armed, since a batch is
  the compiled output of a whole policy and discarding all of it for one bad
  date would be worse than partial arming plus a loud report.
  """

  use GenServer
  require Logger

  alias Anemos.Runtime.Duration

  @default_min_interval_ms 1_000
  @default_max_schedules 1_000

  @typedoc "Why a schedule spec could not be armed."
  @type failure_reason ::
          {:interval_below_minimum, pos_integer(), pos_integer()}
          | {:schedule_limit_exceeded, pos_integer()}
          | {:date_in_past, {integer(), integer(), integer()}}
          | {:unresolvable_nld, String.t()}
          | {:nld_in_past, String.t()}
          | {:unknown_duration_unit, atom()}
          | {:invalid_duration, term()}

  @doc """
  Starts the scheduler.

  ## Options

    * `:name` — process registration name (optional)
    * `:runtime_name` — the Anemos.Runtime name for dispatching events (required)
    * `:dispatch_fn` — override dispatch function for testing (optional)
    * `:min_interval_ms` — interval floor (optional, see moduledoc)
    * `:max_schedules` — cap on armed timers (optional, see moduledoc)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Adds schedule specs to the running scheduler. Timers start immediately.

  Returns `:ok` when every spec was armed, or `{:error, failures}` where
  `failures` is a list of `{event_name, reason}` for the specs that were not.
  Specs not named in `failures` were armed.
  """
  @spec schedule(pid() | atom(), [Anemos.CompiledSchedule.t()]) ::
          :ok | {:error, [{String.t(), failure_reason()}]}
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
      min_interval_ms: limit(opts, :min_interval_ms, :min_schedule_interval_ms, @default_min_interval_ms),
      max_schedules: limit(opts, :max_schedules, :max_schedules, @default_max_schedules),
      timers: %{},
      schedules: []
    }}
  end

  defp limit(opts, opt_key, env_key, default) do
    Keyword.get(opts, opt_key, Application.get_env(:anemos, env_key, default))
  end

  @impl true
  def handle_call({:schedule, new_schedules}, _from, state) do
    {state, failures} =
      Enum.reduce(new_schedules, {state, []}, fn sched, {state, failures} ->
        case arm(sched, state) do
          {:ok, timer_ref} ->
            {%{state |
               timers: Map.put(state.timers, sched.event_name, {timer_ref, sched}),
               schedules: state.schedules ++ [sched]
             }, failures}

          {:error, reason} ->
            Logger.warning(
              "schedule #{sched.event_name} not armed: #{inspect(reason)} — it will never fire"
            )

            {state, [{sched.event_name, reason} | failures]}
        end
      end)

    reply = if failures == [], do: :ok, else: {:error, Enum.reverse(failures)}
    {:reply, reply, state}
  end

  # Cap is checked against timers actually armed, so it holds cumulatively
  # across separate schedule/2 calls.
  defp arm(sched, state) do
    if map_size(state.timers) >= state.max_schedules do
      {:error, {:schedule_limit_exceeded, state.max_schedules}}
    else
      start_timer(sched, state)
    end
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

  # Each clause returns {:ok, timer_ref} or {:error, failure_reason}. Nothing
  # here may return a bare nil: a nil stored in the timers map is a schedule
  # that will never fire, indistinguishable from one that will.
  defp start_timer(%{time_spec: {:interval, dur}, event_name: name, recurrence: :interval}, state) do
    case Duration.to_ms(dur) do
      {:error, reason} ->
        {:error, reason}

      ms when ms < state.min_interval_ms ->
        {:error, {:interval_below_minimum, ms, state.min_interval_ms}}

      ms ->
        {:ok, ref} = :timer.send_interval(ms, {:fire, name})
        {:ok, ref}
    end
  end

  defp start_timer(%{time_spec: {:delay_ms, ms}, event_name: name, recurrence: nil}, _state) do
    {:ok, Process.send_after(self(), {:fire, name}, ms)}
  end

  defp start_timer(%{time_spec: {:time, {h, m}}, event_name: name, recurrence: nil}, _state) do
    ms = ms_until_time(h, m)
    {:ok, Process.send_after(self(), {:fire, name}, ms)}
  end

  defp start_timer(%{time_spec: {:time, {h, m}}, recurrence: recurrence} = sched, _state)
       when recurrence != nil do
    ms = ms_until_next_occurrence(h, m, recurrence)
    {:ok, Process.send_after(self(), {:fire_recurring, sched.event_name, sched}, ms)}
  end

  defp start_timer(%{time_spec: {:date, {y, mo, d}}, event_name: name, recurrence: nil}, _state) do
    case ms_until_date(y, mo, d) do
      ms when ms > 0 -> {:ok, Process.send_after(self(), {:fire, name}, ms)}
      _ -> {:error, {:date_in_past, {y, mo, d}}}
    end
  end

  defp start_timer(%{time_spec: {:day, day}, event_name: name, recurrence: nil}, _state) do
    ms = ms_until_day(day)
    {:ok, Process.send_after(self(), {:fire, name}, ms)}
  end

  defp start_timer(%{time_spec: {:nld, text}, event_name: name, recurrence: nil}, _state) do
    case Anemos.Runtime.NLD.resolve_ms(text) do
      {:ok, ms} when ms > 0 -> {:ok, Process.send_after(self(), {:fire, name}, ms)}
      {:ok, _} -> {:error, {:nld_in_past, text}}
      {:error, _} -> {:error, {:unresolvable_nld, text}}
    end
  end

  # An unrecognised time_spec shape is a compiler bug, not a policy error, but
  # it must not take the scheduler down with every other schedule it holds.
  defp start_timer(sched, _state) do
    {:error, {:unsupported_time_spec, sched.time_spec, sched.recurrence}}
  end

  defp schedule_next_occurrence(%{time_spec: {:time, {h, m}}, recurrence: recurrence} = sched) do
    ms = ms_until_next_occurrence(h, m, recurrence)
    Process.send_after(self(), {:fire_recurring, sched.event_name, sched}, ms)
  end

  # --- Time calculations ---

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

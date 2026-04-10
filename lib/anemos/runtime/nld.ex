defmodule Anemos.Runtime.NLD do
  @moduledoc """
  Natural Language Date resolver.

  Resolves `NLD_<text>` expressions to `NaiveDateTime` values.
  All times are system-local.

  ## Supported expressions

  | Expression | Resolves to |
  |-----------|-------------|
  | `tomorrow` | Next day at 00:00:01 |
  | `yesterday` | Previous day at 00:00:01 |
  | `today` | Current day at 00:00:01 |
  | `next.monday` .. `next.sunday` | Next occurrence of that day at 00:00:01 |
  | `next.week` | Next monday at 00:00:01 |
  | `next.month` | First of next month at 00:00:01 |
  | `next.year` | January 1 of next year at 00:00:01 |
  | `end.of.month` | Last day of current month at 23:59:59 |
  | `end.of.week` | Next sunday at 23:59:59 |

  ## Examples

      iex> {:ok, dt} = Anemos.Runtime.NLD.resolve("today")
      iex> dt.hour
      0

      iex> {:error, :unknown_expression} = Anemos.Runtime.NLD.resolve("gobbledygook")

  """

  @day_names %{
    "monday" => 1,
    "tuesday" => 2,
    "wednesday" => 3,
    "thursday" => 4,
    "friday" => 5,
    "saturday" => 6,
    "sunday" => 7
  }

  @doc """
  Resolves a natural language date expression to a `NaiveDateTime`.

  Returns `{:ok, naive_datetime}` or `{:error, :unknown_expression}`.
  """
  @spec resolve(String.t()) :: {:ok, NaiveDateTime.t()} | {:error, :unknown_expression}
  def resolve(text) do
    now = NaiveDateTime.local_now()
    today = NaiveDateTime.to_date(now)

    case text do
      "today" ->
        {:ok, NaiveDateTime.new!(today, Time.new!(0, 0, 1))}

      "tomorrow" ->
        {:ok, NaiveDateTime.new!(Date.add(today, 1), Time.new!(0, 0, 1))}

      "yesterday" ->
        {:ok, NaiveDateTime.new!(Date.add(today, -1), Time.new!(0, 0, 1))}

      "next.week" ->
        days = days_until_day(today, 1)
        {:ok, NaiveDateTime.new!(Date.add(today, days), Time.new!(0, 0, 1))}

      "next.month" ->
        next = today |> Date.end_of_month() |> Date.add(1)
        {:ok, NaiveDateTime.new!(next, Time.new!(0, 0, 1))}

      "next.year" ->
        {:ok, NaiveDateTime.new!(Date.new!(today.year + 1, 1, 1), Time.new!(0, 0, 1))}

      "end.of.month" ->
        {:ok, NaiveDateTime.new!(Date.end_of_month(today), Time.new!(23, 59, 59))}

      "end.of.week" ->
        days = days_until_day(today, 7)
        {:ok, NaiveDateTime.new!(Date.add(today, days), Time.new!(23, 59, 59))}

      "next." <> day_name ->
        case Map.fetch(@day_names, day_name) do
          {:ok, target} ->
            days = days_until_day(today, target)
            {:ok, NaiveDateTime.new!(Date.add(today, days), Time.new!(0, 0, 1))}

          :error ->
            {:error, :unknown_expression}
        end

      _ ->
        {:error, :unknown_expression}
    end
  end

  @doc """
  Resolves a natural language date to milliseconds from now.

  Returns `{:ok, milliseconds}` or `{:error, :unknown_expression}`.
  """
  @spec resolve_ms(String.t()) :: {:ok, non_neg_integer()} | {:error, :unknown_expression}
  def resolve_ms(text) do
    case resolve(text) do
      {:ok, target} ->
        now = NaiveDateTime.local_now()
        ms = NaiveDateTime.diff(target, now, :millisecond)
        {:ok, max(ms, 0)}

      error ->
        error
    end
  end

  defp days_until_day(today, target_day_num) do
    current = Date.day_of_week(today)
    days = rem(target_day_num - current + 7, 7)
    if days == 0, do: 7, else: days
  end
end

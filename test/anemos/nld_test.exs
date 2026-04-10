defmodule Anemos.NLDTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.NLD
  alias Anemos.{Parser, Compiler}
  alias Anemos.AST

  doctest Anemos.Runtime.NLD

  # --- Resolver tests ---

  test "resolves today" do
    {:ok, dt} = NLD.resolve("today")
    today = Date.utc_today()
    assert NaiveDateTime.to_date(dt) == today
    assert dt.hour == 0 and dt.minute == 0 and dt.second == 1
  end

  test "resolves tomorrow" do
    {:ok, dt} = NLD.resolve("tomorrow")
    tomorrow = Date.add(Date.utc_today(), 1)
    assert NaiveDateTime.to_date(dt) == tomorrow
  end

  test "resolves yesterday" do
    {:ok, dt} = NLD.resolve("yesterday")
    yesterday = Date.add(Date.utc_today(), -1)
    assert NaiveDateTime.to_date(dt) == yesterday
  end

  test "resolves next.monday through next.sunday" do
    for day <- ~w(monday tuesday wednesday thursday friday saturday sunday) do
      {:ok, dt} = NLD.resolve("next.#{day}")
      assert Date.day_of_week(NaiveDateTime.to_date(dt)) == day_number(day)
      assert NaiveDateTime.compare(dt, NaiveDateTime.local_now()) == :gt
    end
  end

  test "resolves next.week to next monday" do
    {:ok, dt} = NLD.resolve("next.week")
    assert Date.day_of_week(NaiveDateTime.to_date(dt)) == 1
    assert NaiveDateTime.compare(dt, NaiveDateTime.local_now()) == :gt
  end

  test "resolves next.month" do
    {:ok, dt} = NLD.resolve("next.month")
    today = Date.utc_today()
    expected_month = if today.month == 12, do: 1, else: today.month + 1
    assert NaiveDateTime.to_date(dt).month == expected_month
    assert NaiveDateTime.to_date(dt).day == 1
  end

  test "resolves next.year" do
    {:ok, dt} = NLD.resolve("next.year")
    assert NaiveDateTime.to_date(dt).year == Date.utc_today().year + 1
    assert NaiveDateTime.to_date(dt).month == 1
    assert NaiveDateTime.to_date(dt).day == 1
  end

  test "resolves end.of.month" do
    {:ok, dt} = NLD.resolve("end.of.month")
    today = Date.utc_today()
    assert NaiveDateTime.to_date(dt) == Date.end_of_month(today)
    assert dt.hour == 23 and dt.minute == 59 and dt.second == 59
  end

  test "resolves end.of.week to next sunday" do
    {:ok, dt} = NLD.resolve("end.of.week")
    assert Date.day_of_week(NaiveDateTime.to_date(dt)) == 7
    assert dt.hour == 23
  end

  test "resolve_ms returns positive milliseconds" do
    {:ok, ms} = NLD.resolve_ms("tomorrow")
    assert ms > 0
  end

  test "unknown expression returns error" do
    assert {:error, :unknown_expression} = NLD.resolve("gobbledygook")
  end

  # --- Lexer tests ---

  test "tokenizes NLD_ prefix" do
    {:ok, tokens} = Anemos.Lexer.tokenize("NLD_tomorrow")
    assert [{:nld_literal, _, "tomorrow"}] = tokens
  end

  test "tokenizes NLD_ with dots" do
    {:ok, tokens} = Anemos.Lexer.tokenize("NLD_next.wednesday")
    assert [{:nld_literal, _, "next.wednesday"}] = tokens
  end

  # --- Parser tests ---

  test "parses at NLD_tomorrow block" do
    input = """
    rule deadline {
      at NLD_tomorrow {
        log "due"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [at_block] = rule.body
    assert %AST.At{time_spec: {:nld, "tomorrow"}} = at_block
  end

  test "parses at NLD_next.wednesday block" do
    input = """
    rule meeting {
      at NLD_next.wednesday {
        log "standup"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [at_block] = rule.body
    assert %AST.At{time_spec: {:nld, "next.wednesday"}} = at_block
  end

  # --- Compiler tests ---

  test "NLD at block produces schedule" do
    input = """
    rule deadline {
      at NLD_tomorrow {
        log "due"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, compiled} = Compiler.compile(ast)

    assert length(compiled.schedules) == 1
    [sched] = compiled.schedules
    assert sched.event_name == "AT_NLD_tomorrow"
    assert sched.time_spec == {:nld, "tomorrow"}
  end

  defp day_number("monday"), do: 1
  defp day_number("tuesday"), do: 2
  defp day_number("wednesday"), do: 3
  defp day_number("thursday"), do: 4
  defp day_number("friday"), do: 5
  defp day_number("saturday"), do: 6
  defp day_number("sunday"), do: 7
end

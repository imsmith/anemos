defmodule Anemos.AtRuleIdentityTest do
  @moduledoc """
  A-61: `at` blocks compiled to a rule name derived from the time spec alone,
  so two `at 08:00` blocks in two unrelated policies both became `at_AT_08_00`.
  With A-15's replace-by-name load, the second silently replaced the first.

  Also A-61's second collision: recurrence was not encoded in the schedule's
  event name, so `at 08:00` and `at 08:00 every weekday` — different firing
  behaviour — shared one key.
  """
  use ExUnit.Case, async: false

  alias Anemos.Runtime.Dispatcher

  setup context do
    tag = context.test |> to_string() |> String.replace(~r/\W/, "_")
    name = :"ari_#{tag}"

    start_supervised!({Anemos.Runtime, name: name})
    %{runtime: name, dispatcher: :"#{name}.dispatcher"}
  end

  defp compile!(source) do
    {:ok, ast} = Anemos.Parser.parse(source)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    compiled
  end

  @policy_a """
  rule morning_report {
    at 08:00 {
      log "report"
    }
  }
  """

  @policy_b """
  rule morning_backup {
    at 08:00 {
      log "backup"
    }
  }
  """

  test "two policies with the same at-time both keep firing", %{dispatcher: d} do
    :ok = Dispatcher.load(d, compile!(@policy_a))
    :ok = Dispatcher.load(d, compile!(@policy_b))

    results = Dispatcher.dispatch(d, "AT_08_00", %{})

    logged =
      results
      |> Enum.map(fn {:ok, %{value: value}} -> value end)
      |> Enum.sort()

    assert logged == ["backup", "report"],
           "an unrelated policy's at-block replaced this one — rule names carry no rule identity"
  end

  test "at rules in different rules get distinct names" do
    [a] = compile!(@policy_a).rules
    [b] = compile!(@policy_b).rules

    refute a.name == b.name, "both at-rules compiled to #{a.name}"
    assert a.name =~ "morning_report"
    assert b.name =~ "morning_backup"
  end

  test "the schedule event name stays shared for a genuinely shared time" do
    [a] = compile!(@policy_a).schedules
    [b] = compile!(@policy_b).schedules

    assert a.event_name == b.event_name,
           "the same wall-clock time must arm one timer, not one per rule"
  end

  test "recurrence is encoded in the schedule event name" do
    [plain] =
      compile!("""
      rule once {
        at 08:00 {
          log "once"
        }
      }
      """).schedules

    [weekday] =
      compile!("""
      rule repeatedly {
        at 08:00 every weekday {
          log "again"
        }
      }
      """).schedules

    refute plain.event_name == weekday.event_name,
           "one-shot and recurring 08:00 collide on #{plain.event_name}"
  end

  test "two rules sharing a recurrence still share one event name" do
    [a] =
      compile!("""
      rule a {
        at 08:00 every weekday {
          log "a"
        }
      }
      """).schedules

    [b] =
      compile!("""
      rule b {
        at 08:00 every weekday {
          log "b"
        }
      }
      """).schedules

    assert a.event_name == b.event_name
  end

  test "different recurrences at the same time do not collide" do
    for {left, right} <- [{"day", "weekday"}, {"weekday", "weekend"}, {"monday", "friday"}] do
      [l] =
        compile!("""
        rule l {
          at 08:00 every #{left} {
            log "l"
          }
        }
        """).schedules

      [r] =
        compile!("""
        rule r {
          at 08:00 every #{right} {
            log "r"
          }
        }
        """).schedules

      refute l.event_name == r.event_name, "#{left} and #{right} share #{l.event_name}"
    end
  end

  test "a condition's at block subscribes to the same event its schedule arms" do
    compiled =
      compile!("""
      condition due {
        at 08:00 every weekday {
          log "due"
        }
      }
      """)

    [sched] = compiled.schedules
    [condition] = compiled.conditions

    assert sched.event_name in condition.subscriptions
  end
end

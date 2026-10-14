defmodule Anemos.CompoundTriggerTest do
  @moduledoc """
  A-47. `when (A AND B)` is a compound state: true if and only if A and B are
  both true as last reported. A report stands until the next report of the
  same event. `when` is "when the condition holds, do": every report is a
  check, and every check that finds the state true fires the block.
  """
  use ExUnit.Case, async: false
  doctest Anemos.Runtime.Report

  alias Anemos.Runtime

  @off %{context_data: %{"state" => false}}

  setup context do
    rt = :"ct_#{:erlang.phash2(context.test)}"
    start_supervised!({Runtime, name: rt})
    {:ok, rt: rt}
  end

  defp fired(rt, event, context \\ %{}) do
    {:ok, results} = Runtime.dispatch(rt, event, context)
    for %{type: :log, value: v} <- results, do: v
  end

  describe "AND in a rule" do
    setup %{rt: rt} do
      :ok =
        Runtime.load(rt, """
        rule both {
          when (A AND B) {
            log "both"
          }
        }
        """)
    end

    test "one operand alone does not fire", %{rt: rt} do
      assert fired(rt, "A") == []
      assert fired(rt, "A") == []
    end

    test "fires when the second operand reports true", %{rt: rt} do
      assert fired(rt, "A") == []
      assert fired(rt, "B") == ["both"]
    end

    test "fires at every report at which the state is true", %{rt: rt} do
      fired(rt, "A")
      assert fired(rt, "B") == ["both"]
      assert fired(rt, "A") == ["both"]
      assert fired(rt, "B") == ["both"]
    end

    test "does not fire while either operand's last report is false", %{rt: rt} do
      fired(rt, "A")
      assert fired(rt, "B") == ["both"]
      assert fired(rt, "A", @off) == []
      assert fired(rt, "B") == []
      assert fired(rt, "A") == ["both"]
    end

    test "a false report is the operand's state until its next report", %{rt: rt} do
      assert fired(rt, "A", @off) == []
      assert fired(rt, "B") == []
      assert fired(rt, "B") == []
    end
  end

  test "lowercase `and` is the same trigger", %{rt: rt} do
    :ok = Runtime.load(rt, ~s|rule r { when (A and B) { log "both" } }|)
    assert fired(rt, "A") == []
    assert fired(rt, "B") == ["both"]
  end

  test "three operands need all three", %{rt: rt} do
    :ok = Runtime.load(rt, ~s|rule r { when (A AND B AND C) { log "all" } }|)
    assert fired(rt, "A") == []
    assert fired(rt, "B") == []
    assert fired(rt, "C") == ["all"]
  end

  test "a report outside the rule's context is not heard", %{rt: rt} do
    :ok =
      Runtime.load(rt, """
      rule scoped {
        context home.garage
        when (A AND B) {
          log "both"
        }
      }
      """)

    assert fired(rt, "A", %{context_path: "office"}) == []
    assert fired(rt, "B", %{context_path: "home.garage"}) == []
    assert fired(rt, "A", %{context_path: "home.garage"}) == ["both"]
  end

  test "a sibling `when` firing does not disturb the compound state", %{rt: rt} do
    :ok =
      Runtime.load(rt, """
      rule r {
        when OTHER {
          log "other"
        }
        when (A AND B) {
          log "both"
        }
      }
      """)

    fired(rt, "A")
    assert fired(rt, "OTHER") == ["other"]
    assert fired(rt, "B") == ["both"]
    assert fired(rt, "OTHER") == ["other"]
    assert fired(rt, "A") == ["both"]
    assert fired(rt, "A", @off) == []
    assert fired(rt, "OTHER") == ["other"]
    assert fired(rt, "A") == ["both"]
  end

  test "A-17: a sibling `when` firing leaves an armed dwell timer armed", %{rt: rt} do
    :ok =
      Runtime.load(rt, """
      rule r {
        when OTHER {
          log "other"
        }
        when SIGNAL for 10min {
          log "dwelt"
        }
      }
      """)

    fired(rt, "SIGNAL")
    fired(rt, "OTHER")

    assert [%{dwell: [%{event: "SIGNAL", state: :armed}]}] = Runtime.describe(rt).rules
  end

  test "`for` dwells on the compound state, not on either operand", %{rt: rt} do
    :ok = Runtime.load(rt, ~s|rule r { when (A AND B) for 10min { log "dwelt" } }|)

    fired(rt, "A")
    assert [%{dwell: dwell}] = Runtime.describe(rt).rules
    refute Enum.any?(dwell, &(&1.state == :armed))

    fired(rt, "B")
    assert [%{dwell: [%{state: :armed}]}] = Runtime.describe(rt).rules

    fired(rt, "A", @off)
    assert [%{dwell: [%{state: :listening}]}] = Runtime.describe(rt).rules
  end

  test "compound state is not shown as a `set` binding", %{rt: rt} do
    :ok = Runtime.load(rt, ~s|rule r { when (A AND B) { log "both" } }|)
    fired(rt, "A")
    assert [%{bindings: bindings}] = Runtime.describe(rt).rules
    assert bindings == %{}
  end

  describe "OR in a rule" do
    setup %{rt: rt} do
      :ok = Runtime.load(rt, ~s|rule r { when (A OR B) { log "either" } }|)
    end

    test "fires at every report at which the state is true", %{rt: rt} do
      assert fired(rt, "A") == ["either"]
      assert fired(rt, "A") == ["either"]
      assert fired(rt, "B") == ["either"]
    end

    test "every operand's report is recorded, though one already decided it", %{rt: rt} do
      assert fired(rt, "A") == ["either"]
      assert fired(rt, "B") == ["either"]
      # B was recorded true while A already held the state true, so A
      # reporting false is a check that still finds it true.
      assert fired(rt, "A", @off) == ["either"]
      assert fired(rt, "B", @off) == []
    end

    test "does not fire when every operand's last report is false", %{rt: rt} do
      assert fired(rt, "A", @off) == []
      assert fired(rt, "B", @off) == []
    end
  end

  describe "AND in a condition" do
    setup %{rt: rt} do
      :ok =
        Runtime.load(rt, """
        condition both {
          when (A AND B) {
            log "became true"
          }
        }
        """)
    end

    test "is true only while both are true as last reported", %{rt: rt} do
      fired(rt, "A")
      refute Runtime.condition_state(rt, "both")
      assert fired(rt, "B") == ["became true"]
      assert Runtime.condition_state(rt, "both")
      assert fired(rt, "A") == []
      assert Runtime.condition_state(rt, "both")
      fired(rt, "B", @off)
      refute Runtime.condition_state(rt, "both")
      assert fired(rt, "B") == ["became true"]
    end
  end
end

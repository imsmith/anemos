defmodule Anemos.NextEventArgsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-55. `nextevent <target> with { key: expr }`, wired symmetrically with the
  `nextrule` support added for A-51.

  `%AST.NextEvent{}` declared an `args` field that both parser clauses hardcoded
  to `nil` and that no consumer read — the only member of that family with
  neither a producer nor a reader. The decision was to wire it rather than
  delete it, so a `nextevent` hands its target the same kind of payload a
  `nextrule` does, and the two flow-control statements stop differing for no
  stated reason.
  """

  alias Anemos.AST

  defp logs(results), do: for(%{type: :log, value: v} <- results, do: v)

  defp next_event(source) do
    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(source)
    [%AST.When{body: body} | _] = rule.body
    Enum.find(body, &match?(%AST.NextEvent{}, &1))
  end

  # --- Parsing ---

  test "nextevent without a with block still parses, args nil" do
    ne =
      next_event("""
      rule r {
        when EV {
          nextevent OTHER
        }
      }
      """)

    assert %AST.NextEvent{target: "OTHER", args: nil} = ne
  end

  test "nextevent with a with block parses into BlockArgs pairs" do
    ne =
      next_event("""
      rule r {
        when EV {
          nextevent OTHER with { key: "value" }
        }
      }
      """)

    assert %AST.NextEvent{target: "OTHER", args: %AST.BlockArgs{pairs: pairs}} = ne
    assert [{"key", %AST.Literal{type: :string, value: "value"}}] = pairs
  end

  test "a lowercase identifier target takes a with block too" do
    ne =
      next_event("""
      rule r {
        when EV {
          nextevent other.event with { key: 1 }
        }
      }
      """)

    assert %AST.NextEvent{args: %AST.BlockArgs{pairs: [{"key", _}]}} = ne
  end

  test "a with block accepts several pairs, comma- or newline-separated" do
    ne =
      next_event("""
      rule r {
        when EV {
          nextevent OTHER with {
            a: 1,
            b: "two"
            c: ?forwarded
          }
        }
      }
      """)

    assert %AST.NextEvent{args: %AST.BlockArgs{pairs: pairs}} = ne
    assert Enum.map(pairs, &elem(&1, 0)) == ["a", "b", "c"]
  end

  test "an empty with block parses to no pairs" do
    ne =
      next_event("""
      rule r {
        when EV {
          nextevent OTHER with { }
        }
      }
      """)

    assert %AST.NextEvent{args: %AST.BlockArgs{pairs: []}} = ne
  end

  test "a with block missing its value is a positioned parse error" do
    assert {:error, message} =
             Anemos.Parser.parse("""
             rule r {
               when EV {
                 nextevent OTHER with { key: }
               }
             }
             """)

    assert message =~ "line 3"
  end

  # --- Delivery, end to end ---

  test "resolved args reach the target when block as context data" do
    source = """
    rule r {
      when DRIVE {
        nextevent LANDED with { who: "alpha" }
      }

      when LANDED {
        log ?who
      }
    }
    """

    {:ok, results} = Anemos.run(source, event: "DRIVE")
    assert "alpha" in logs(results)
  end

  test "an arg expression is resolved against the sending block's bindings" do
    source = """
    rule r {
      when DRIVE {
        let name = "beta"
        nextevent LANDED with { who: @name }
      }

      when LANDED {
        log ?who
      }
    }
    """

    {:ok, results} = Anemos.run(source, event: "DRIVE")
    assert "beta" in logs(results)
  end

  test "args merge into the originating event's context rather than replacing it" do
    source = """
    rule r {
      when DRIVE {
        nextevent LANDED with { added: "new" }
      }

      when LANDED {
        log ?original
        log ?added
      }
    }
    """

    {:ok, results} = Anemos.run(source, event: "DRIVE", context_data: %{"original" => "kept"})
    assert "kept" in logs(results)
    assert "new" in logs(results)
  end

  test "nextevent without args leaves the target reading the originating context" do
    source = """
    rule r {
      when DRIVE {
        nextevent LANDED
      }

      when LANDED {
        log ?original
      }
    }
    """

    {:ok, results} = Anemos.run(source, event: "DRIVE", context_data: %{"original" => "kept"})
    assert "kept" in logs(results)
  end
end

defmodule Anemos.LoopTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.AST

  test "While struct has condition and body" do
    node = %AST.While{condition: :cond, body: [:stmt], line: 1}
    assert node.condition == :cond
    assert node.body == [:stmt]
    assert node.line == 1
  end

  test "For struct has var, iterable, and body" do
    node = %AST.For{var: "x", iterable: :list, body: [:stmt], line: 1}
    assert node.var == "x"
    assert node.iterable == :list
    assert node.body == [:stmt]
  end

  # --- Parser tests ---

  test "parses while loop" do
    input = """
    rule r {
      when EV {
        while $count > 0 {
          log "tick"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.While{} = w]}] = rule.body
    assert %AST.BinaryOp{op: :>} = w.condition
    assert [%AST.Log{}] = w.body
  end

  test "parses for-in loop" do
    input = """
    rule r {
      when EV {
        for item in ?items {
          log @item
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.For{} = f]}] = rule.body
    assert f.var == "item"
    assert %AST.VarRef{sigil: "?"} = f.iterable
    assert f.keyword == :for
  end

  test "parses each loop" do
    input = """
    rule r {
      when EV {
        each item {
          log @item
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.For{} = f]}] = rule.body
    assert f.var == "item"
    assert f.iterable == nil
    assert f.keyword == :each
  end

  test "parses foreach MODULE::verb loop" do
    input = """
    rule r {
      when EV {
        foreach FILE::list {
          log @item
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{body: [%AST.For{} = f]}] = rule.body
    assert %AST.Command{module: "FILE", verb: "list"} = f.iterable
    assert f.keyword == :foreach
  end
end

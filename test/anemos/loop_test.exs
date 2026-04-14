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

  # --- Compiler tests ---

  test "while loop compiles and executes" do
    input = """
    rule r {
      when EV {
        set count = 3
        while $count > 0 {
          log $count
          set count = $count - 1
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [3, 2, 1]
  end

  test "for-in loop iterates over list" do
    input = """
    rule r {
      when EV {
        for x in ?items {
          log @x
        }
      }
    }
    """

    context = %{context_data: %{"items" => [1, 2, 3]}}
    {:ok, results} = Anemos.run(input, event: "EV", context: context)
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == [1, 2, 3]
  end

  test "while loop with zero iterations produces no ops" do
    input = """
    rule r {
      when EV {
        set count = 0
        while $count > 0 {
          log "never"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    assert results == []
  end

  test "while loop safety limit prevents infinite loops" do
    input = """
    rule r {
      when EV {
        while true {
          log "infinite"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert length(log_values) == 10_000
  end
end

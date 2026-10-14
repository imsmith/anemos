defmodule Anemos.ElseifTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{AST, Compiler, Parser}

  # --- Parser tests ---

  test "parses if/elseif chain (no else)" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [%AST.When{body: [%AST.If{} = outer]}] = rule.body
    assert [%AST.If{} = inner] = outer.else_body
    assert [%AST.Log{expression: %AST.Literal{value: "second"}}] = inner.body
  end

  test "parses if/elseif/else chain" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "d" {
          log "second"
        } else {
          log "third"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [%AST.When{body: [%AST.If{} = outer]}] = rule.body
    assert [%AST.If{} = inner] = outer.else_body
    assert [%AST.Log{expression: %AST.Literal{value: "third"}}] = inner.else_body
  end

  test "parses long elseif chain (four arms)" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "1"
        } elseif "a" eq "c" {
          log "2"
        } elseif "a" eq "d" {
          log "3"
        } else {
          log "4"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [%AST.When{body: [arm1]}] = rule.body
    assert %AST.If{body: [%AST.Log{expression: %AST.Literal{value: "1"}}]} = arm1
    assert [arm2] = arm1.else_body
    assert %AST.If{body: [%AST.Log{expression: %AST.Literal{value: "2"}}]} = arm2
    assert [arm3] = arm2.else_body
    assert %AST.If{body: [%AST.Log{expression: %AST.Literal{value: "3"}}]} = arm3
    assert [%AST.Log{expression: %AST.Literal{value: "4"}}] = arm3.else_body
  end

  test "parses two-token 'else if' form equivalently" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } else if "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [%AST.When{body: [%AST.If{} = outer]}] = rule.body

    assert [%AST.If{body: [%AST.Log{expression: %AST.Literal{value: "second"}}]}] =
             outer.else_body
  end

  # --- End-to-end execution tests ---

  test "elseif fires when first branch is false and elseif is true" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["second"]
  end

  test "first branch wins over elseif when both true" do
    input = """
    rule r {
      when EV {
        if "a" eq "a" {
          log "first"
        } elseif "b" eq "b" {
          log "second"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["first"]
  end

  test "else fires when all preceding branches false" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "a" eq "c" {
          log "second"
        } else {
          log "third"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["third"]
  end

  test "mid-chain match: only the matching arm fires" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "1"
        } elseif "a" eq "c" {
          log "2"
        } elseif "a" eq "a" {
          log "3"
        } elseif "a" eq "d" {
          log "4"
        } else {
          log "5"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["3"]
  end

  test "no else, all-false chain produces no log ops" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "1"
        } elseif "a" eq "c" {
          log "2"
        }
      }
    }
    """

    {:ok, results} = Anemos.run(input, event: "EV")
    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == []
  end

  test "compiler walks elseif as nested If" do
    input = """
    rule r {
      when EV {
        if "a" eq "b" {
          log "first"
        } elseif "c" eq "c" {
          log "second"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, ops, _} = compiled.handler.("EV", %{}, %{})
    assert [%{type: :log, value: "second"}] = ops
  end
end

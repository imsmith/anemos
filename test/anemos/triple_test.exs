defmodule Anemos.TripleTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.{Parser, Compiler}
  alias Anemos.AST

  # --- Parser tests ---

  test "parses triple assertion with arrows" do
    input = """
    rule facts {
      when EV {
        let [:p001 -> :knows -> :p002]
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [let_stmt] = when_block.body
    assert %AST.Let{name: nil, value: %AST.Triple{}} = let_stmt
    assert let_stmt.value.subject.value == "p001"
    assert let_stmt.value.predicate.value == "knows"
    assert let_stmt.value.object.value == "p002"
  end

  test "parses triple query with spaces" do
    input = """
    rule query {
      when EV {
        log [?a :worksOn ?p]
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [log_stmt] = when_block.body
    assert %AST.Log{expression: %AST.Triple{}} = log_stmt
    assert log_stmt.expression.subject.sigil == "?"
    assert log_stmt.expression.subject.name == "a"
    assert log_stmt.expression.predicate.value == "worksOn"
    assert log_stmt.expression.object.sigil == "?"
    assert log_stmt.expression.object.name == "p"
  end

  test "parses triple query with all atoms" do
    input = """
    rule query {
      when EV {
        log [:p001 :knows :p002]
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [log_stmt] = when_block.body
    assert %AST.Triple{} = log_stmt.expression
  end

  test "commands still parse correctly after triple support" do
    input = """
    rule cmd {
      when EV {
        [DEVICE::set "light" "on"]
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [cmd] = when_block.body
    assert %AST.Command{module: "DEVICE", verb: "set"} = cmd
  end

  # --- Compiler tests ---

  test "triple assertion compiles to assert_triple op" do
    input = """
    rule facts {
      when EV {
        let [:p001 -> :knows -> :p002]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("EV", %{}, %{})
    assert [%{type: :assert_triple, subject: "p001", predicate: "knows", object: "p002"}] = ops
  end

  test "triple query compiles to triple_query" do
    input = """
    rule query {
      when EV {
        log [?a :worksOn ?p]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    {:ok, ops, _} = compiled.handler.("EV", %{}, %{})
    assert [%{type: :log, value: %{type: :triple_query, subject: {:var, "a"}, predicate: "worksOn", object: {:var, "p"}}}] = ops
  end

  # --- Runtime integration ---

  test "assert and query triples through runtime" do
    start_supervised!({Anemos.Runtime, name: :test_triples})

    # Assert some facts
    Anemos.Runtime.load(:test_triples, """
    rule setup {
      when SETUP {
        let [:p001 -> :knows -> :p002]
        let [:p001 -> :worksOn -> :proj1]
        let [:p002 -> :worksOn -> :proj1]
        log "facts asserted"
      }
    }
    """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_triples, "SETUP")

    assert_ops = Enum.filter(results, &match?(%{type: :assert_triple}, &1))
    assert length(assert_ops) == 3
  end

  # --- Triple store unit tests ---

  test "triple store assert and query" do
    {:ok, store} = Anemos.Runtime.TripleStore.start_link()

    Anemos.Runtime.TripleStore.assert_triple(store, "p001", "knows", "p002")
    Anemos.Runtime.TripleStore.assert_triple(store, "p001", "worksOn", "proj1")

    results = Anemos.Runtime.TripleStore.query(store, "p001", "knows", :_)
    assert [{"p001", "knows", "p002"}] = results

    results = Anemos.Runtime.TripleStore.query(store, "p001", :_, :_)
    assert length(results) == 2

    results = Anemos.Runtime.TripleStore.query(store, :_, :_, :_)
    assert length(results) == 2
  end

  test "triple store match with variables" do
    {:ok, store} = Anemos.Runtime.TripleStore.start_link()

    Anemos.Runtime.TripleStore.assert_triple(store, "p001", "worksOn", "proj1")
    Anemos.Runtime.TripleStore.assert_triple(store, "p002", "worksOn", "proj1")
    Anemos.Runtime.TripleStore.assert_triple(store, "p003", "worksOn", "proj2")

    results = Anemos.Runtime.TripleStore.match(store, {:var, "who"}, "worksOn", "proj1")
    assert length(results) == 2
    names = Enum.map(results, & &1["who"])
    assert "p001" in names
    assert "p002" in names
  end

  test "triple store deduplicates" do
    {:ok, store} = Anemos.Runtime.TripleStore.start_link()

    Anemos.Runtime.TripleStore.assert_triple(store, "a", "b", "c")
    Anemos.Runtime.TripleStore.assert_triple(store, "a", "b", "c")

    results = Anemos.Runtime.TripleStore.query(store, :_, :_, :_)
    assert length(results) == 1
  end
end

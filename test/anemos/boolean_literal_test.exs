defmodule Anemos.BooleanLiteralTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-46. The language must have boolean literals.

  Before the fix, `true` in policy source lexed as an identifier and the
  parser produced `%AST.Literal{type: :identifier, value: "true"}` — a
  binary. `?flag == true` was therefore a comparison against the *string*
  `"true"`, so a host supplying a genuine boolean got a guard that never
  fired and a host supplying the string got one that did. Inverted from
  intent, not merely dead.
  """

  import ExUnit.CaptureLog

  alias Anemos.AST

  defp logs(results), do: for(%{type: :log, value: v} <- results, do: v)

  defp guard_source do
    """
    rule flagged {
      when EV {
        if ?flag == true {
          log "fired"
        }
      }
    }
    """
  end

  # --- Lexing ---

  test "true and false lex as boolean tokens, not identifiers" do
    {:ok, tokens} = Anemos.Lexer.tokenize("true false")

    assert [{:boolean, _, true}, {:boolean, _, false}] = tokens
  end

  test "identifiers with a boolean prefix are unaffected" do
    {:ok, tokens} = Anemos.Lexer.tokenize("truebeam falsely")

    assert [{:identifier, _, "truebeam"}, {:identifier, _, "falsely"}] = tokens
  end

  # --- Parsing ---

  test "a boolean literal parses to a boolean-typed Literal carrying a boolean" do
    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(guard_source())

    [%AST.When{body: [%AST.If{condition: condition}]}] = rule.body

    assert %AST.BinaryOp{
             op: :==,
             left: %AST.VarRef{sigil: "?", name: "flag"},
             right: %AST.Literal{type: :boolean, value: true}
           } = condition
  end

  # --- The reproduction from ISSUES.md A-46 ---

  test "a genuine boolean from the host satisfies == true" do
    {:ok, results} =
      Anemos.run(guard_source(), event: "EV", context: %{context_data: %{"flag" => true}})

    assert "fired" in logs(results)
  end

  test "a genuine boolean from the host satisfies == false" do
    source = """
    rule flagged {
      when EV {
        if ?flag == false {
          log "fired"
        }
      }
    }
    """

    {:ok, results} =
      Anemos.run(source, event: "EV", context: %{context_data: %{"flag" => false}})

    assert "fired" in logs(results)
  end

  test "unless ... == true is not inverted" do
    source = """
    rule flagged {
      when EV unless ?maintenance == true {
        log "ran"
      }
    }
    """

    {:ok, suppressed} =
      Anemos.run(source, event: "EV", context: %{context_data: %{"maintenance" => true}})

    refute "ran" in logs(suppressed)

    {:ok, allowed} =
      Anemos.run(source, event: "EV", context: %{context_data: %{"maintenance" => false}})

    assert "ran" in logs(allowed)
  end

  test "!= false is satisfied by a genuine boolean true" do
    source = """
    rule flagged {
      when EV {
        if ?flag != false {
          log "fired"
        }
      }
    }
    """

    {:ok, results} =
      Anemos.run(source, event: "EV", context: %{context_data: %{"flag" => true}})

    assert "fired" in logs(results)
  end

  # --- The documented decision: no coercion, but the mismatch is loud ---

  test "a string-valued host payload still compares against a string literal" do
    source = """
    rule flagged {
      when EV {
        if ?flag == "true" {
          log "fired"
        }
      }
    }
    """

    {:ok, results} =
      Anemos.run(source, event: "EV", context: %{context_data: %{"flag" => "true"}})

    assert "fired" in logs(results)
  end

  test "comparing a boolean against a boolean-shaped string warns instead of failing silently" do
    log =
      capture_log(fn ->
        {:ok, results} =
          Anemos.run(guard_source(), event: "EV", context: %{context_data: %{"flag" => "true"}})

        refute "fired" in logs(results)
      end)

    assert log =~ "boolean/string mismatch"
  end

  test "the reverse mismatch — a string literal against a boolean payload — also warns" do
    source = """
    rule flagged {
      when EV {
        if ?flag == "true" {
          log "fired"
        }
      }
    }
    """

    log =
      capture_log(fn ->
        {:ok, results} =
          Anemos.run(source, event: "EV", context: %{context_data: %{"flag" => true}})

        refute "fired" in logs(results)
      end)

    assert log =~ "boolean/string mismatch"
  end

  test "an ordinary string comparison does not warn" do
    source = """
    rule flagged {
      when EV {
        if ?name == "alpha" {
          log "fired"
        }
      }
    }
    """

    log =
      capture_log(fn ->
        {:ok, results} =
          Anemos.run(source, event: "EV", context: %{context_data: %{"name" => "beta"}})

        refute "fired" in logs(results)
      end)

    refute log =~ "boolean/string mismatch"
  end
end

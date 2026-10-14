defmodule Anemos.NextRuleArgsTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-51. `nextrule <target> with { key: expr }` must parse into
  `%AST.NextRule{args: %AST.BlockArgs{}}`.

  Before the fix `parse_nextrule/1` hardcoded `args: nil` and
  `%AST.BlockArgs{}` was never constructed anywhere in the parser, which made
  the compiler's resolution clause (`eval_statement/3` on `%AST.NextRule{}`)
  and the dispatcher's arg merge unreachable from source text.

  The syntax is the one the design notes and the language sketches use —
  `nextrule normalize-metadata with { file: [FILE::path] }` — not a bare
  brace block.
  """

  alias Anemos.AST

  defp logs(results), do: for(%{type: :log, value: v} <- results, do: v)

  # --- Lexing ---

  test "a bare colon lexes as its own delimiter" do
    {:ok, tokens} = Anemos.Lexer.tokenize("{ key: 1 }")

    assert [
             {:lbrace, _, _},
             {:identifier, _, "key"},
             {:colon, _, _},
             {:integer, _, 1},
             {:rbrace, _, _}
           ] = tokens
  end

  test "an atom literal still wins over the bare colon" do
    {:ok, tokens} = Anemos.Lexer.tokenize(":alpha")

    assert [{:atom, _, "alpha"}] = tokens
  end

  test "the :: operator still wins over two bare colons" do
    {:ok, tokens} = Anemos.Lexer.tokenize("FILE::path")

    assert [{:module_id, _, "FILE"}, {:double_colon, _, _}, {:identifier, _, "path"}] = tokens
  end

  # A-08 stays honoured: `with` keys are author-invented names with no closed
  # set to validate against, so they must remain binaries all the way through.
  test "parsing many unique with-block keys does not grow the atom table" do
    prefix = "wq#{:erlang.unique_integer([:positive])}x"

    pairs = Enum.map_join(1..2_000, ",\n    ", &"#{prefix}#{&1}: #{&1}")

    source = """
    rule r {
      when EV {
        nextrule other with {
          #{pairs}
        }
      }
    }
    """

    # Warm every lazily-loaded code path before measuring.
    {:ok, _} = Anemos.Parser.parse("rule w { when EV { nextrule o with { a: 1 } } }")

    before = :erlang.system_info(:atom_count)
    {:ok, _} = Anemos.Parser.parse(source)
    growth = :erlang.system_info(:atom_count) - before

    assert growth < 200,
           "parsing 2000 unique with-block keys interned #{growth} atoms; keys must stay binaries"
  end

  # --- Parsing ---

  defp next_rule(source) do
    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(source)
    [%AST.When{body: body}] = rule.body
    Enum.find(body, &match?(%AST.NextRule{}, &1))
  end

  test "nextrule without a with block still parses, args nil" do
    nr =
      next_rule("""
      rule r {
        when EV {
          nextrule other-rule
        }
      }
      """)

    assert %AST.NextRule{target: "other-rule", args: nil} = nr
  end

  test "nextrule with a with block parses into BlockArgs pairs" do
    nr =
      next_rule("""
      rule r {
        when EV {
          nextrule other-rule with { key: "value" }
        }
      }
      """)

    assert %AST.NextRule{target: "other-rule", args: %AST.BlockArgs{pairs: pairs}} = nr
    assert [{"key", %AST.Literal{type: :string, value: "value"}}] = pairs
  end

  test "a with block accepts several pairs, comma- or newline-separated" do
    nr =
      next_rule("""
      rule r {
        when EV {
          nextrule other-rule with {
            a: 1,
            b: "two"
            c: ?forwarded
          }
        }
      }
      """)

    assert %AST.NextRule{args: %AST.BlockArgs{pairs: pairs}} = nr
    assert Enum.map(pairs, &elem(&1, 0)) == ["a", "b", "c"]
  end

  test "an empty with block parses to no pairs" do
    nr =
      next_rule("""
      rule r {
        when EV {
          nextrule other-rule with { }
        }
      }
      """)

    assert %AST.NextRule{args: %AST.BlockArgs{pairs: []}} = nr
  end

  test "a with block missing its value is a positioned parse error" do
    assert {:error, %{message: message}} =
             Anemos.Parser.parse("""
             rule r {
               when EV {
                 nextrule other-rule with { key: }
               }
             }
             """)

    assert message =~ "line 3"
  end

  # --- Delivery, end to end ---

  test "resolved args reach the target rule as context data" do
    source = """
    rule driver {
      when DRIVE {
        nextrule target with { who: "alpha" }
      }
    }

    rule target {
      when TICK {
        log ?who
      }
    }
    """

    {:ok, results} = Anemos.run(source, event: "DRIVE")
    assert "alpha" in logs(results)
  end

  test "an arg expression is resolved against the sending rule's bindings" do
    source = """
    rule driver {
      when DRIVE {
        let name = "beta"
        nextrule target with { who: @name }
      }
    }

    rule target {
      when TICK {
        log ?who
      }
    }
    """

    {:ok, results} = Anemos.run(source, event: "DRIVE")
    assert "beta" in logs(results)
  end
end

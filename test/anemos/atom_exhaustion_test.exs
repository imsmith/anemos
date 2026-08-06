# SPDX-License-Identifier: AGPL-3.0-or-later
defmodule Anemos.AtomExhaustionTest do
  @moduledoc """
  Atoms are never garbage collected. Exceeding the BEAM atom table limit is an
  unrecoverable `system_limit` abort of the entire node — not a supervised
  crash. `Anemos.Runtime.load/2` accepts arbitrary policy text at runtime, so
  no lexer or parser path may intern an atom derived from untrusted source.

  A policy PARSE FAILURE is recoverable. Atom exhaustion is not. These tests
  assert the asymmetry is respected: unbounded source constructs stay binaries,
  and closed-set constructs reject unknown members with a normal error.
  """
  use ExUnit.Case, async: false

  alias Anemos.{Lexer, Parser}

  # Number of distinct source-derived names each growth test feeds the lexer.
  @n 5_000

  # Slack for atoms the runtime legitimately creates during a test (module
  # loading, ExUnit bookkeeping). Anything proportional to @n blows past this.
  @slack 200

  # Lazily-loaded modules intern their own atoms on first call, a fixed ~230 that
  # would otherwise be charged to whichever test ran first. Force every measured
  # code path to be warm before any measurement.
  setup_all do
    Lexer.tokenize("rule r warm DAY_monday 5min --required :a")
    Lexer.tokenize("DAY_notaday")
    Parser.parse("rule r { at 09:00 every notaday { log \"x\" } }")
    Parser.parse("query q { expect :a\n eng { select ?x }\n return ?x }")
    :ok
  end

  defp novel_prefix, do: "zq#{:erlang.unique_integer([:positive])}x"

  # DAY_ literals accept lowercase letters only, so counters must be spelled
  # out rather than written as digits.
  defp letters(n), do: n |> Integer.to_string() |> String.replace(~r/\d/, &<<?a + String.to_integer(&1)>>)

  defp novel_letter_prefix, do: "zq#{letters(:erlang.unique_integer([:positive]))}x"

  defp atom_growth(fun) do
    before = :erlang.system_info(:atom_count)
    fun.()
    :erlang.system_info(:atom_count) - before
  end

  describe "identifier interning" do
    test "lexing many unique identifiers does not grow the atom table" do
      prefix = novel_prefix()
      source = Enum.map_join(1..@n, " ", &"#{prefix}#{&1}")

      growth = atom_growth(fn -> {:ok, _} = Lexer.tokenize(source) end)

      assert growth < @slack,
             "lexing #{@n} unique identifiers interned #{growth} atoms; " <>
               "identifiers must remain binaries"
    end

    test "identifiers are still binaries and keywords are still atoms" do
      assert {:ok, tokens} = Lexer.tokenize("rule foo when EVENT and bar")

      assert [
               {:keyword, _, :rule},
               {:identifier, _, "foo"},
               {:keyword, _, :when},
               {:module_id, _, "EVENT"},
               {:word_operator, _, :and},
               {:identifier, _, "bar"}
             ] = tokens
    end

    test "an identifier whose text matches a keyword only by prefix is not a keyword" do
      assert {:ok, [{:identifier, _, "rulebook"}]} = Lexer.tokenize("rulebook")
      assert {:ok, [{:identifier, _, "andy"}]} = Lexer.tokenize("andy")
    end
  end

  describe "query expect atoms" do
    test "many unique expect names do not grow the atom table" do
      prefix = novel_prefix()
      names = Enum.map_join(1..@n, ", ", &":#{prefix}#{&1}")

      source = """
      query q {
        expect #{names}
        eng { select ?x }
        return ?x
      }
      """

      growth = atom_growth(fn -> {:ok, _} = Parser.parse(source) end)

      assert growth < @slack,
             "parsing #{@n} unique expect names interned #{growth} atoms"
    end
  end

  describe "DAY_ literals are a closed set" do
    test "every weekday still lexes" do
      for day <- ~w(monday tuesday wednesday thursday friday saturday sunday) do
        assert {:ok, [{:day_literal, _, atom}]} = Lexer.tokenize("DAY_#{day}")
        assert atom == String.to_existing_atom(day)
      end
    end

    test "an unknown weekday is a lexer error, not a new atom" do
      prefix = novel_letter_prefix()

      growth =
        atom_growth(fn ->
          for i <- 1..@n do
            assert {:error, msg, _line, _col} = Lexer.tokenize("DAY_#{prefix}#{letters(i)}")
            assert msg =~ "day"
          end
        end)

      assert growth < @slack,
             "lexing #{@n} unknown DAY_ literals interned #{growth} atoms"
    end
  end

  describe "recurrence names are a closed set" do
    test "known recurrences still parse" do
      for rec <- ~w(day weekday weekend monday sunday) do
        source = "rule r { at 09:00 every #{rec} { log \"x\" } }"
        assert {:ok, _} = Parser.parse(source), "every #{rec} failed to parse"
      end
    end

    test "an unknown recurrence is a parse error, not a new atom" do
      prefix = novel_prefix()

      growth =
        atom_growth(fn ->
          for i <- 1..@n do
            source = "rule r { at 09:00 every #{prefix}#{i} { log \"x\" } }"
            assert {:error, _} = Parser.parse(source)
          end
        end)

      assert growth < @slack,
             "parsing #{@n} unknown recurrence names interned #{growth} atoms"
    end
  end

  describe "duration units and demand flags stay bounded" do
    test "duration units resolve to known atoms" do
      assert {:ok, [{:duration, _, {5, :min}}]} = Lexer.tokenize("5min")
      assert {:ok, [{:duration, _, {30, :s}}]} = Lexer.tokenize("30s")
    end

    test "demand flags resolve to known atoms" do
      assert {:ok, [{:demand_flag, _, :required}]} = Lexer.tokenize("--required")
      assert {:ok, [{:demand_flag, _, :sufficient}]} = Lexer.tokenize("--sufficient")
    end
  end
end

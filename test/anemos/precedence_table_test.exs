defmodule Anemos.PrecedenceTableTest do
  @moduledoc """
  Pins the operator precedence table against transcription error.

  The table used to be a hand-aligned map literal, grouped by level
  typographically. A-27 restructured it into `{level, [operators]}` tuples so
  the grouping is data rather than whitespace. This test exists because a slip
  during that kind of restructuring is silent and severe: an operator landing
  one level off changes what every policy using it means, and nothing else in
  the suite would notice.

  `@expected` is written as level-to-operators here too, deliberately. Written
  as a flat map it would be a second hand-maintained transcription of the same
  data — the thing most likely to drift from the source it is checking.
  """
  use ExUnit.Case, async: true

  # Language spec section 7.1. Lowest binding power first.
  @levels [
    {0, ~w(|>)a},
    {1, ~w(in notin contains starts_with ends_with matches_glob matches_regex memberof)a},
    {2, ~w(|| or)a},
    {3, ~w(&& and)a},
    {4, ~w(|)a},
    {5, ~w(^)a},
    {6, ~w(&)a},
    {7, ~w(== != === !== eq ne)a},
    {8, ~w(< <= > >= lt le gt ge)a},
    {9, [:"<<", :">>"]},
    {10, ~w(+ -)a},
    {11, ~w(* / %)a}
  ]

  @expected for {level, ops} <- @levels, op <- ops, into: %{}, do: {op, level}

  test "the derived precedence table matches the spec 7.1 table" do
    assert Anemos.Parser.precedence_table() == @expected
  end

  test "every operator appears at exactly one level" do
    all = for {_level, ops} <- @levels, op <- ops, do: op
    assert length(all) == length(Enum.uniq(all))
    assert map_size(Anemos.Parser.precedence_table()) == length(all)
  end
end

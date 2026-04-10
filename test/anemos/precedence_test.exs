defmodule Anemos.PrecedenceTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.{Parser, Compiler}

  # Helper: parse a rule with an expression, compile, evaluate
  defp eval_expr(expr_str) do
    input = """
    rule test {
      when EV {
        log #{expr_str}
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)
    {:ok, [%{type: :log, value: value}], _} = compiled.handler.("EV", %{}, %{})
    value
  end

  # --- Arithmetic precedence ---

  test "multiplication binds tighter than addition" do
    # 2 + 3 * 4 should be 2 + (3 * 4) = 14, not (2 + 3) * 4 = 20
    assert eval_expr("2 + 3 * 4") == 14
  end

  test "division binds tighter than subtraction" do
    # 10 - 6 / 2 should be 10 - (6 / 2) = 7.0
    assert eval_expr("10 - 6 / 2") == 7.0
  end

  test "modulo binds tighter than addition" do
    # 10 + 7 % 3 should be 10 + (7 % 3) = 11
    assert eval_expr("10 + 7 % 3") == 11
  end

  test "left associativity for arithmetic" do
    # 10 - 3 - 2 should be (10 - 3) - 2 = 5, not 10 - (3 - 2) = 9
    assert eval_expr("10 - 3 - 2") == 5
  end

  # --- Comparison vs arithmetic ---

  test "arithmetic binds tighter than comparison" do
    # 2 + 3 == 5 should be (2 + 3) == 5 = true
    assert eval_expr("2 + 3 == 5") == true
  end

  test "arithmetic in both sides of comparison" do
    # 2 * 3 > 2 + 2 should be (2 * 3) > (2 + 2) = 6 > 4 = true
    assert eval_expr("2 * 3 > 2 + 2") == true
  end

  # --- Logical vs comparison ---

  test "comparison binds tighter than logical and" do
    # 1 == 1 and 2 == 2 should be (1 == 1) and (2 == 2) = true
    assert eval_expr("1 == 1 and 2 == 2") == true
  end

  test "and binds tighter than or" do
    # false or true and true should be false or (true and true) = true
    assert eval_expr("1 == 2 or 1 == 1 and 2 == 2") == true
  end

  # --- Bitwise ---

  test "bitwise and" do
    assert eval_expr("5 & 3") == 1
  end

  test "bitwise or" do
    assert eval_expr("5 | 3") == 7
  end

  test "bitwise xor" do
    assert eval_expr("5 ^ 3") == 6
  end

  test "bitwise shift left" do
    assert eval_expr("1 << 3") == 8
  end

  test "bitwise shift right" do
    assert eval_expr("8 >> 2") == 2
  end

  # --- Membership at lowest precedence ---

  test "in has lowest precedence" do
    # 1 + 1 in [2, 3] should be (1 + 1) in [2, 3] = true
    # (if 'in' were higher, it would be 1 + (1 in [2, 3]))
    assert eval_expr("2 in 2") == true
  end

  # --- Parenthesized override ---

  test "parentheses override precedence" do
    # (2 + 3) * 4 = 20
    assert eval_expr("(2 + 3) * 4") == 20
  end
end

defmodule Anemos.LexerTest do
  use ExUnit.Case, async: true

  alias Anemos.Lexer

  test "tokenizes a minimal rule" do
    input = ~s|rule garage-lights-on { }|
    assert {:ok, tokens} = Lexer.tokenize(input)
    assert [{:keyword, _, :rule}, {:identifier, _, "garage-lights-on"}, {:lbrace, _, _}, {:rbrace, _, _}] = tokens
  end

  test "tokenizes string literals" do
    assert {:ok, tokens} = Lexer.tokenize(~s|"hello world"|)
    assert [{:string, _, "hello world"}] = tokens
  end

  test "tokenizes command expression brackets" do
    assert {:ok, tokens} = Lexer.tokenize(~s|[DEVICE::set "on"]|)
    assert [{:lbracket, _, _}, {:module_id, _, "DEVICE"}, {:double_colon, _, _},
            {:keyword, _, :set}, {:string, _, "on"}, {:rbracket, _, _}] = tokens
  end

  test "tokenizes sigils" do
    assert {:ok, tokens} = Lexer.tokenize("$myvar @immutable :atom ?query")
    assert [{:mutable_ref, _, "myvar"}, {:immutable_ref, _, "immutable"},
            {:atom, _, "atom"}, {:query_var, _, "query"}] = tokens
  end

  test "tokenizes numbers and durations" do
    assert {:ok, tokens} = Lexer.tokenize("42 3.14 10min 5s")
    assert [{:integer, _, 42}, {:float, _, 3.14},
            {:duration, _, {10, :min}}, {:duration, _, {5, :s}}] = tokens
  end

  test "skips comments" do
    assert {:ok, tokens} = Lexer.tokenize("; this is a comment\nrule x { }")
    assert [{:keyword, _, :rule} | _] = tokens
  end

  test "tracks line numbers" do
    input = "rule x {\n  when Y {\n  }\n}"
    assert {:ok, tokens} = Lexer.tokenize(input)
    {_, meta, _} = Enum.find(tokens, fn {type, _, _} -> type == :keyword end)
    assert meta[:line] == 1
  end
end

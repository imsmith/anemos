defmodule Anemos.LexerTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Anemos.Lexer

  doctest Anemos.Lexer

  test "tokenizes a minimal rule" do
    input = ~s|rule garage-lights-on { }|
    assert {:ok, tokens} = Lexer.tokenize(input)

    assert [
             {:keyword, _, :rule},
             {:identifier, _, "garage-lights-on"},
             {:lbrace, _, _},
             {:rbrace, _, _}
           ] = tokens
  end

  test "tokenizes string literals" do
    assert {:ok, tokens} = Lexer.tokenize(~s|"hello world"|)
    assert [{:string, _, "hello world"}] = tokens
  end

  test "tokenizes command expression brackets" do
    assert {:ok, tokens} = Lexer.tokenize(~s|[DEVICE::set "on"]|)

    assert [
             {:lbracket, _, _},
             {:module_id, _, "DEVICE"},
             {:double_colon, _, _},
             {:keyword, _, :set},
             {:string, _, "on"},
             {:rbracket, _, _}
           ] = tokens
  end

  test "tokenizes sigils" do
    assert {:ok, tokens} = Lexer.tokenize("$myvar @immutable :atom ?query")

    assert [
             {:mutable_ref, _, "myvar"},
             {:immutable_ref, _, "immutable"},
             {:atom, _, "atom"},
             {:query_var, _, "query"}
           ] = tokens
  end

  test "tokenizes numbers and durations" do
    assert {:ok, tokens} = Lexer.tokenize("42 3.14 10min 5s")

    assert [
             {:integer, _, 42},
             {:float, _, 3.14},
             {:duration, _, {10, :min}},
             {:duration, _, {5, :s}}
           ] = tokens
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

  test "tokenizes CONDITION_name as a single module_id token" do
    assert {:ok, tokens} = Lexer.tokenize("CONDITION_networkchanged")
    assert [{:module_id, _, "CONDITION_networkchanged"}] = tokens
  end

  test "tokenizes mixed-case module event like SENSOR_MOTION_DETECTED" do
    assert {:ok, tokens} = Lexer.tokenize("SENSOR_MOTION_DETECTED")
    assert [{:module_id, _, "SENSOR_MOTION_DETECTED"}] = tokens
  end

  test "tokenizes HH:MM time literal" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("at 13:00 {")
    assert [{:keyword, _, :at}, {:time_literal, _, {13, 0}}, {:lbrace, _, _}] = tokens
  end

  test "tokenizes TIME_HHMM prefixed time" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("TIME_1300")
    assert [{:time_literal, _, {13, 0}}] = tokens
  end

  test "tokenizes DATE_YYYY.MM.DD" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("DATE_2026.04.15")
    assert [{:date_literal, _, {2026, 4, 15}}] = tokens
  end

  test "tokenizes DAY_weekday" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("DAY_monday")
    assert [{:day_literal, _, :monday}] = tokens
  end

  test "tokenizes interval keyword" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("interval(5min)")
    assert [{:keyword, _, :interval}, {:lparen, _, _}, {:duration, _, {5, :min}}, {:rparen, _, _}] = tokens
  end

  test "tokenizes data keyword" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("data reserved-ips { }")
    assert [{:keyword, _, :data}, {:identifier, _, "reserved-ips"}, {:lbrace, _, _}, {:rbrace, _, _}] = tokens
  end

  test "tokenizes query keyword" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("query movie { }")
    assert [{:keyword, _, :query}, {:identifier, _, "movie"}, {:lbrace, _, _}, {:rbrace, _, _}] = tokens
  end

  test "tokenizes data block keywords" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("source expect transclude dynamic subscribe periodic memberof global")
    keywords = for {:keyword, _, k} <- tokens, do: k
    assert :source in keywords
    assert :expect in keywords
    assert :transclude in keywords
    assert :dynamic in keywords
    assert :subscribe in keywords
    assert :periodic in keywords
    assert :memberof in keywords
    assert :global in keywords
  end
end

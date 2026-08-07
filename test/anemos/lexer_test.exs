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

    assert [{:keyword, _, :interval}, {:lparen, _, _}, {:duration, _, {5, :min}}, {:rparen, _, _}] =
             tokens
  end

  test "tokenizes data keyword" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("data reserved-ips { }")

    assert [
             {:keyword, _, :data},
             {:identifier, _, "reserved-ips"},
             {:lbrace, _, _},
             {:rbrace, _, _}
           ] = tokens
  end

  test "tokenizes query keyword" do
    assert {:ok, tokens} = Anemos.Lexer.tokenize("query movie { }")

    assert [{:keyword, _, :query}, {:identifier, _, "movie"}, {:lbrace, _, _}, {:rbrace, _, _}] =
             tokens
  end

  test "tokenizes data block keywords" do
    assert {:ok, tokens} =
             Anemos.Lexer.tokenize(
               "source expect transclude dynamic subscribe periodic memberof global"
             )

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

  # --- IPv4 / IPv6 ---

  test "tokenizes IPv4 address with CIDR" do
    assert {:ok, tokens} = Lexer.tokenize("10.0.0.0/8")
    assert [{:ip_addr, _, "10.0.0.0/8"}] = tokens
  end

  test "tokenizes IPv4 address without CIDR" do
    assert {:ok, tokens} = Lexer.tokenize("192.168.1.1")
    assert [{:ip_addr, _, "192.168.1.1"}] = tokens
  end

  test "tokenizes IPv4 max address" do
    assert {:ok, tokens} = Lexer.tokenize("255.255.255.255/32")
    assert [{:ip_addr, _, "255.255.255.255/32"}] = tokens
  end

  test "tokenizes IPv4 default route" do
    assert {:ok, tokens} = Lexer.tokenize("0.0.0.0/0")
    assert [{:ip_addr, _, "0.0.0.0/0"}] = tokens
  end

  test "tokenizes IPv6 link-local with CIDR" do
    assert {:ok, tokens} = Lexer.tokenize("fe80::/10")
    assert [{:ip_addr, _, "fe80::/10"}] = tokens
  end

  test "tokenizes IPv6 loopback with CIDR" do
    assert {:ok, tokens} = Lexer.tokenize("::1/128")
    assert [{:ip_addr, _, "::1/128"}] = tokens
  end

  test "tokenizes IPv6 unspecified with CIDR" do
    assert {:ok, tokens} = Lexer.tokenize("::/128")
    assert [{:ip_addr, _, "::/128"}] = tokens
  end

  test "tokenizes IPv6 full form" do
    assert {:ok, tokens} = Lexer.tokenize("2001:db8::1")
    assert [{:ip_addr, _, "2001:db8::1"}] = tokens
  end

  test "tokenizes IPv6 full expanded form" do
    assert {:ok, tokens} = Lexer.tokenize("2001:0db8:0000:0000:0000:0000:0000:0001")
    assert [{:ip_addr, _, "2001:0db8:0000:0000:0000:0000:0000:0001"}] = tokens
  end

  test "tokenizes IPv6 ULA with CIDR" do
    assert {:ok, tokens} = Lexer.tokenize("fc00::/7")
    assert [{:ip_addr, _, "fc00::/7"}] = tokens
  end

  test "does not confuse module::verb with IPv6" do
    assert {:ok, tokens} = Lexer.tokenize("DEVICE::set")
    assert [{:module_id, _, "DEVICE"}, {:double_colon, _, _}, {:keyword, _, :set}] = tokens
  end

  test "tokenizes data block with IP addresses" do
    input = """
    data reserved-ips {
      10.0.0.0/8
      192.168.0.0/16
      fe80::/10
    }
    """

    assert {:ok, tokens} = Lexer.tokenize(input)
    ip_tokens = for {:ip_addr, _, val} <- tokens, do: val
    assert "10.0.0.0/8" in ip_tokens
    assert "192.168.0.0/16" in ip_tokens
    assert "fe80::/10" in ip_tokens
  end
end

defmodule Anemos.LiteralSigilsTest do
  # Spec §2.3 <size>, §2.5 `~r` / `~s`, §10.2 `systemd(...)`. All four were
  # listed in TODO.md as having no lexer or parser support.
  use ExUnit.Case, async: true

  alias Anemos.{Lexer, Parser}

  defp run(body, opts \\ []) do
    source = "rule r { when EV { #{body} } }"
    {:ok, results} = Anemos.run(source, [event: "EV"] ++ opts)
    for %{type: :log, value: v} <- results, do: v
  end

  describe "size literals" do
    test "lex to a byte count, binary multiples" do
      assert {:ok, [{:size, _, 1024}]} = Lexer.tokenize("1KB")
      assert {:ok, [{:size, _, 7}]} = Lexer.tokenize("7B")
      assert {:ok, [{:size, _, 3_145_728}]} = Lexer.tokenize("3MB")
      assert {:ok, [{:size, _, 2_147_483_648}]} = Lexer.tokenize("2GB")
      assert {:ok, [{:size, _, 1_099_511_627_776}]} = Lexer.tokenize("1TB")
    end

    test "compare as integers" do
      assert ["big"] = run(~S|if 2KB gt 2047 { log "big" } else { log "small" }|)
      assert ["eq"] = run(~S|if 1MB eq 1048576 { log "eq" }|)
    end

    test "an unknown unit is not a size" do
      assert {:ok, [{:integer, _, 10}, {:module_id, _, "XB"}]} = Lexer.tokenize("10XB")
    end
  end

  describe "~s string sigil" do
    test "is a string with any paired delimiter and no escaping" do
      assert {:ok, [{:string, _, ~S|say "hi"|}]} = Lexer.tokenize(~S|~s(say "hi")|)
      assert {:ok, [{:string, _, "a(b)c"}]} = Lexer.tokenize("~s[a(b)c]")
      assert {:ok, [{:string, _, "x"}]} = Lexer.tokenize("~s{x}")
      assert {:ok, [{:string, _, "x"}]} = Lexer.tokenize("~s<x>")
      assert {:ok, [{:string, _, "x"}]} = Lexer.tokenize("~s|x|")
      assert {:ok, [{:string, _, "x"}]} = Lexer.tokenize("~s/x/")
    end

    test "logs like a quoted string" do
      assert [~S|say "hi"|] = run(~S|log ~s(say "hi")|)
    end

    test "bitwise ~ is untouched" do
      assert {:ok, [{:operator, _, :"~"}, {:integer, _, 1}]} = Lexer.tokenize("~1")
    end
  end

  describe "~r regex sigil" do
    test "lexes to pattern and flags" do
      assert {:ok, [{:regex, _, {"a+b", ""}}]} = Lexer.tokenize("~r/a+b/")
      assert {:ok, [{:regex, _, {"a+b", "i"}}]} = Lexer.tokenize("~r/a+b/i")
      assert {:ok, [{:regex, _, {"x/y", ""}}]} = Lexer.tokenize("~r(x/y)")
    end

    test "parses to a compiled Regex literal" do
      {:ok, ast} =
        Parser.parse(~S|rule r { when EV { if "x" matches_regex ~r/X/i { log "y" } } }|)

      [
        %{
          body: [
            %{body: [%{condition: %{right: %Anemos.AST.Literal{type: :regex, value: %Regex{}}}}]}
          ]
        }
      ] =
        ast.declarations
    end

    test "matches_regex accepts a regex literal and still accepts a string" do
      assert ["lit"] = run(~S|if "Hello" matches_regex ~r/^h/i { log "lit" }|)
      assert ["str"] = run(~S|if "Hello" matches_regex "^H" { log "str" }|)
      assert [] = run(~S|if "Hello" matches_regex ~r/^h/ { log "no" }|)
    end

    test "an invalid pattern is a syntax error with the line" do
      assert {:error, %Comn.Errors.ErrorStruct{code: "anemos.parser/syntax_error", message: msg}} =
               Parser.parse(~S"""
               rule r { when EV {
                 if "x" matches_regex ~r/(/ { log "y" } } }
               """)

      assert msg =~ "regex"
      assert msg =~ "line 2"
    end
  end

  describe "systemd destination" do
    test "parses like service and rides the emit operation" do
      {:ok, ast} =
        Parser.parse(
          ~S|rule r { when EV { emit [DEVICE::set "a" "b"] to systemd(foo-bar.service) } }|
        )

      [%{body: [%{body: [%Anemos.AST.Emit{destination: {:systemd, "foo-bar.service"}}]}]}] =
        ast.declarations

      {:ok, results} =
        Anemos.run(
          ~S|rule r { when EV { emit [DEVICE::set "a" "b"] to systemd(foo-bar.service) } }|,
          event: "EV",
          modules: %{"DEVICE" => Anemos.Runtime.Modules.Device}
        )

      assert [%{type: :emit, destination: {:systemd, "foo-bar.service"}}] = results
    end
  end
end

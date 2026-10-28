defmodule Anemos.LabelInterpolationTest do
  # `as <label>` where the label carries `:{?var}` — spec §2.4:
  #   <label> ::= <atom> | <atom> "." "{" <query-var> "}"
  # Both shipped forms: `:{?hostname}.network.ip` and `ddns.update.:{?fqdn}`.
  # Listed in TODO.md as "parses but inert" since 2026-08; this closes it.
  use ExUnit.Case, async: true

  alias Anemos.AST

  defp emit_label(source, event, opts) do
    {:ok, results} =
      Anemos.run(
        source,
        [event: event, modules: %{"DEVICE" => Anemos.Runtime.Modules.Device}] ++ opts
      )

    results
  end

  describe "lexer" do
    test "keeps the interpolated expression and the dotted suffix apart" do
      {:ok, tokens} = Anemos.Lexer.tokenize(":{?host}.network.ip")
      assert [{:interp_atom, _, {"?host", ".network.ip"}}] = tokens

      {:ok, tokens} = Anemos.Lexer.tokenize(":{?host}")
      assert [{:interp_atom, _, {"?host", ""}}] = tokens
    end
  end

  describe "parser" do
    test "prefix form becomes [var, static]" do
      {:ok, ast} =
        Anemos.Parser.parse(~S|rule r { when EV { emit [DEVICE::set "x" "y"] as :{?host}.ip } }|)

      [%{body: [%{body: [%AST.Emit{label: label}]}]}] = ast.declarations
      assert [%AST.VarRef{sigil: "?", name: "host"}, ".ip"] = label
    end

    test "suffix form becomes [static, var]" do
      {:ok, ast} =
        Anemos.Parser.parse(
          ~S|rule r { when EV { emit [DEVICE::set "x" "y"] as ddns.update.:{?fqdn} } }|
        )

      [%{body: [%{body: [%AST.Emit{label: label}]}]}] = ast.declarations
      assert ["ddns.update.", %AST.VarRef{sigil: "?", name: "fqdn"}] = label
    end

    test "a plain label is still a string" do
      {:ok, ast} =
        Anemos.Parser.parse(~S|rule r { when EV { emit [DEVICE::set "x" "y"] as plain.label } }|)

      [%{body: [%{body: [%AST.Emit{label: "plain.label"}]}]}] = ast.declarations
    end

    test "only a ?variable may sit inside the braces" do
      assert {:error, %Comn.Errors.ErrorStruct{code: "anemos.parser/syntax_error", message: msg}} =
               Anemos.Parser.parse(
                 ~S|rule r { when EV { emit [DEVICE::set "x" "y"] as x.:{@fqdn} } }|
               )

      assert msg =~ "?variable"
      assert msg =~ "line 1"
    end
  end

  describe "runtime" do
    test "the label is rendered from context data at emit time" do
      source = ~S|rule r { when EV { emit [DEVICE::set "x" "y"] as ddns.update.:{?fqdn} } }|

      assert [%{type: :emit, label: "ddns.update.host.example"}] =
               emit_label(source, "EV", context_data: %{"fqdn" => "host.example"})
    end

    test "prefix form renders too" do
      source = ~S|rule r { when EV { emit [DEVICE::set "x" "y"] as :{?host}.network.ip } }|

      assert [%{type: :emit, label: "box.network.ip"}] =
               emit_label(source, "EV", context_data: %{"host" => "box"})
    end

    test "an unsupplied variable is a structured error, not a partial label" do
      source = ~S|rule r { when EV { emit [DEVICE::set "x" "y"] as ddns.update.:{?fqdn} } }|

      assert [
               {:error,
                %Comn.Errors.ErrorStruct{code: "anemos.runtime/unbound_label", field: "fqdn"}}
             ] =
               emit_label(source, "EV", [])
    end
  end
end

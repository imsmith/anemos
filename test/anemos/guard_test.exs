defmodule Anemos.GuardTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.AST

  # --- Parser tests ---

  test "parses when block with unless guard" do
    input = """
    rule r {
      when EV unless $disabled {
        log "fired"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{guard: {:unless, %AST.VarRef{sigil: "$", name: "disabled"}}}] = rule.body
  end

  test "parses when block with until guard" do
    input = """
    rule r {
      when EV until $done {
        log "fired"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{guard: {:until, %AST.VarRef{sigil: "$", name: "done"}}}] = rule.body
  end

  test "parses if block with unless guard" do
    input = """
    rule r {
      when EV {
        if true unless $skip {
          log "guarded"
        }
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)

    [%AST.When{body: [%AST.If{guard: {:unless, %AST.VarRef{sigil: "$", name: "skip"}}}]}] =
      rule.body
  end

  test "parses when with duration and guard" do
    input = """
    rule r {
      when EV for 10min unless $paused {
        log "fired"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{duration: {10, :min}, guard: {:unless, _}}] = rule.body
  end

  test "when without guard has nil guard" do
    input = """
    rule r {
      when EV {
        log "no guard"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{guard: nil}] = rule.body
  end

  test "parses at block with unless guard" do
    input = """
    rule r {
      at 08:00 unless $paused {
        log "morning"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.At{guard: {:unless, %AST.VarRef{sigil: "$", name: "paused"}}}] = rule.body
  end

  test "parses compound when with guard" do
    input = """
    rule r {
      when (EV1 OR EV2) unless $disabled {
        log "fired"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{event: {:compound, :or, _}, guard: {:unless, _}}] = rule.body
  end

  test "parses module::name when with guard" do
    input = """
    rule r {
      when SENSOR::motion unless $disabled {
        log "fired"
      }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Anemos.Parser.parse(input)
    [%AST.When{event: "SENSOR::motion", guard: {:unless, _}}] = rule.body
  end

  # --- Compiler tests ---

  test "unless guard skips block when expression is truthy" do
    input = """
    rule r {
      when EV unless $disabled {
        log "fired"
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    rule = hd(compiled.rules)

    # Guard condition is false -> block fires
    {:ok, ops, _} = rule.handler.("EV", %{}, %{})
    assert [%{type: :log, value: "fired"}] = ops

    # Guard condition is true -> block skipped
    {:ok, ops, _} = rule.handler.("EV", %{}, %{{:set, "disabled"} => true})
    assert ops == []
  end

  test "until guard stops firing after expression becomes true" do
    input = """
    rule r {
      when EV until $done {
        log "fired"
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    rule = hd(compiled.rules)

    # First call: $done is nil/false -> fires
    {:ok, ops1, persist1} = rule.handler.("EV", %{}, %{})
    assert [%{type: :log, value: "fired"}] = ops1

    # Second call: $done becomes true -> guard trips, skips
    {:ok, ops2, persist2} =
      rule.handler.("EV", %{}, Map.merge(persist1, %{{:set, "done"} => true}))

    assert ops2 == []

    # Third call: stays tripped
    {:ok, ops3, _} = rule.handler.("EV", %{}, persist2)
    assert ops3 == []
  end

  test "unless guard on if block" do
    input = """
    rule r {
      when EV {
        if true unless $skip {
          log "guarded-if"
        }
      }
    }
    """

    {:ok, ast} = Anemos.Parser.parse(input)
    {:ok, compiled} = Anemos.Compiler.compile(ast)
    rule = hd(compiled.rules)

    # Without $skip -> fires
    {:ok, ops, _} = rule.handler.("EV", %{}, %{})
    assert [%{type: :log, value: "guarded-if"}] = ops

    # With $skip set -> skipped
    {:ok, ops, _} = rule.handler.("EV", %{}, %{{:set, "skip"} => true})
    assert ops == []
  end

  # --- End-to-end tests ---

  test "end-to-end: unless guard with context data" do
    input = """
    rule r {
      when EV unless ?maintenance {
        log "running"
      }
    }
    """

    {:ok, results} =
      Anemos.run(input, event: "EV", context: %{context_data: %{"maintenance" => false}})

    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == ["running"]

    {:ok, results} =
      Anemos.run(input, event: "EV", context: %{context_data: %{"maintenance" => true}})

    log_values = for %{type: :log, value: v} <- results, do: v
    assert log_values == []
  end
end

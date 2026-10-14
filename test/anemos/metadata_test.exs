defmodule Anemos.MetadataTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.AST
  alias Anemos.{Compiler, Parser}

  test "parses version metadata" do
    input = """
    rule versioned {
      version "1.2.0"
      when EV { log "hi" }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    assert rule.meta == %{version: "1.2.0"}
  end

  test "parses signed_by metadata" do
    input = """
    rule signed {
      signed_by :admin
      when EV { log "hi" }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    assert rule.meta == %{signed_by: "admin"}
  end

  test "parses scope metadata" do
    input = """
    rule global-rule {
      scope global
      when EV { log "hi" }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    assert rule.meta == %{scope: :global}
  end

  test "parses all three metadata fields" do
    input = """
    rule full {
      version "2.0.0"
      signed_by :operator
      scope mesh

      when EV { log "hi" }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    assert rule.meta.version == "2.0.0"
    assert rule.meta.signed_by == "operator"
    assert rule.meta.scope == :mesh
  end

  test "rule without metadata has nil meta" do
    input = """
    rule bare {
      when EV { log "hi" }
    }
    """

    {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    assert rule.meta == nil
  end

  test "metadata carries through to compiled rule" do
    input = """
    rule versioned {
      version "1.0.0"
      signed_by :deployer
      scope local

      when EV { log "hi" }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    assert compiled.meta.version == "1.0.0"
    assert compiled.meta.signed_by == "deployer"
    assert compiled.meta.scope == :local
    assert compiled.meta.context_path == nil
  end

  test "metadata and context coexist" do
    input = """
    rule both {
      version "1.0.0"
      scope global

      context infra.networking {
        when EV { log "hi" }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, %{rules: [compiled]}} = Compiler.compile(ast)

    assert compiled.meta.version == "1.0.0"
    assert compiled.meta.scope == :global
    assert compiled.meta.context_path == "infra.networking"
  end
end

defmodule Anemos.CompilerTest do
  use ExUnit.Case, async: true

  alias Anemos.{Compiler, Parser}

  doctest Anemos.Compiler

  test "compiles a rule to a module with handle_event/2" do
    input = """
    rule garage-lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, modules} = Compiler.compile(ast)

    assert [compiled] = modules
    assert compiled.name == "garage-lights-on"
    assert compiled.subscriptions == ["SENSOR_MOTION_DETECTED"]
    assert is_function(compiled.handler, 2)
  end

  test "compiled handler returns operations list" do
    input = """
    rule test-rule {
      when TEST_EVENT {
        [DEVICE::set "light" "on"]
        log "done"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})

    assert [%{module: "DEVICE", verb: "set", args: ["light", "on"]}, %{type: :log, value: "done"}] =
             ops
  end

  test "if/else handling in compiled handler" do
    input = """
    rule cond-rule {
      when TEST_EVENT {
        if "a" eq "a" {
          log "yes"
        } else {
          log "no"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :log, value: "yes"}] = ops
  end

  test "if/else takes else branch when condition is false" do
    input = """
    rule cond-rule {
      when TEST_EVENT {
        if "a" eq "b" {
          log "yes"
        } else {
          log "no"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :log, value: "no"}] = ops
  end

  test "let bindings are available as variable references" do
    input = """
    rule let-rule {
      when TEST_EVENT {
        let x = "hello"
        log $x
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :log, value: "hello"}] = ops
  end

  test "let binding with command produces command operation" do
    input = """
    rule let-cmd-rule {
      when TEST_EVENT {
        let title = [PDF::title]
        log $title
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    # let with a command value stores the command op; log resolves $title to it
    assert [
             %{type: :command, module: "PDF", verb: "title", args: []},
             %{type: :log, value: %{type: :command, module: "PDF", verb: "title", args: []}}
           ] = ops
  end

  test "emit operations are compiled" do
    input = """
    rule emit-rule {
      when TEST_EVENT {
        emit [EVENT::fire]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})

    assert [%{type: :emit, value: %{type: :command, module: "EVENT", verb: "fire", args: []}}] =
             ops
  end

  test "emit with type and label" do
    input = """
    rule emit-typed {
      when TEST_EVENT {
        emit state [EVENT::fire] as :my.label
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :emit, emit_type: :state, label: "my.label"}] = ops
  end

  test "multiple when blocks in a rule produce multiple compiled rules" do
    input = """
    rule multi-when {
      when EVENT_A {
        log "a"
      }
      when EVENT_B {
        log "b"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, modules} = Compiler.compile(ast)

    assert length(modules) == 2
    [a, b] = modules
    assert a.name == "multi-when"
    assert a.subscriptions == ["EVENT_A"]
    assert b.name == "multi-when"
    assert b.subscriptions == ["EVENT_B"]

    {:ok, ops_a} = a.handler.("EVENT_A", %{})
    assert [%{type: :log, value: "a"}] = ops_a

    {:ok, ops_b} = b.handler.("EVENT_B", %{})
    assert [%{type: :log, value: "b"}] = ops_b
  end

  test "compound event subscriptions" do
    input = """
    rule compound-rule {
      when (INFRA::ip4 OR INFRA::ip6) {
        log "ip changed"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    assert compiled.subscriptions == ["INFRA::ip4", "INFRA::ip6"]
  end

  test "demand produces demand operation" do
    input = """
    rule demand-rule {
      when TEST_EVENT {
        demand katachora-ddns-key
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :demand, capability: "katachora-ddns-key"}] = ops
  end

  test "set produces set operation" do
    input = """
    rule set-rule {
      when TEST_EVENT {
        set x = "value"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :set, name: "x", value: "value"}] = ops
  end

  test "ne comparison in if block" do
    input = """
    rule ne-rule {
      when TEST_EVENT {
        if "a" ne "b" {
          log "different"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :log, value: "different"}] = ops
  end

  test "context blocks are traversed for when blocks" do
    input = """
    rule ctx-rule {
      context "garage.motion" {
        when SENSOR_MOTION_DETECTED {
          log "motion"
        }
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    assert compiled.subscriptions == ["SENSOR_MOTION_DETECTED"]
    {:ok, ops} = compiled.handler.("SENSOR_MOTION_DETECTED", %{})
    assert [%{type: :log, value: "motion"}] = ops
  end

  test "command with var ref argument resolves from context" do
    input = """
    rule varref-rule {
      when TEST_EVENT {
        let name = "world"
        [DEVICE::set "greeting" $name]
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :command, module: "DEVICE", verb: "set", args: ["greeting", "world"]}] = ops
  end

  # --- Error-path / edge-case tests ---

  test "empty program (no declarations) returns {:ok, []}" do
    ast = %Anemos.AST.Program{declarations: []}
    assert {:ok, []} = Compiler.compile(ast)
  end

  test "rule with no when blocks produces no compiled rules" do
    ast = %Anemos.AST.Program{
      declarations: [
        %Anemos.AST.Rule{
          name: "empty-rule",
          body: [
            %Anemos.AST.Log{expression: %Anemos.AST.Literal{value: "orphan"}}
          ]
        }
      ]
    }

    assert {:ok, []} = Compiler.compile(ast)
  end

  test "unresolvable $nonexistent variable reference returns nil" do
    input = """
    rule varref-missing {
      when TEST_EVENT {
        log $nonexistent
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, [compiled]} = Compiler.compile(ast)

    {:ok, ops} = compiled.handler.("TEST_EVENT", %{})
    assert [%{type: :log, value: nil}] = ops
  end

  test "multiple rules in program" do
    input = """
    rule a {
      when X {
        log "a"
      }
    }
    rule b {
      when Y {
        log "b"
      }
    }
    """

    {:ok, ast} = Parser.parse(input)
    {:ok, modules} = Compiler.compile(ast)

    assert length(modules) == 2
    names = Enum.map(modules, & &1.name)
    assert "a" in names
    assert "b" in names
  end
end

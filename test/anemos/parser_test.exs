defmodule Anemos.ParserTest do
  use ExUnit.Case, async: true

  alias Anemos.{Parser, AST}

  test "parses minimal rule with when block and command" do
    input = """
    rule garage-lights-on {
      context "garage.motion.sensor" {
        when SENSOR_MOTION_DETECTED {
          [DEVICE::set "garage.lights" "on"]
        }
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    assert %AST.Rule{name: "garage-lights-on"} = rule
    assert [%AST.Context{path: "garage.motion.sensor", body: [when_block]}] = rule.body
    assert %AST.When{event: "SENSOR_MOTION_DETECTED"} = when_block
    assert [%AST.Command{module: "DEVICE", verb: "set", args: args}] = when_block.body
    assert ["garage.lights", "on"] = Enum.map(args, fn %AST.Literal{value: v} -> v end)
  end

  test "parses when block with duration" do
    input = """
    rule lights-off {
      when SENSOR_NO_MOTION for 10min {
        [DEVICE::set "garage.lights" "off"]
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    assert %AST.When{event: "SENSOR_NO_MOTION", duration: {10, :min}} = when_block
  end

  test "parses let binding" do
    input = """
    rule test {
      when FILE_CREATED {
        let title = [PDF::title]
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [let_stmt] = when_block.body
    assert %AST.Let{name: "title", value: %AST.Command{module: "PDF", verb: "title"}} = let_stmt
  end

  test "parses if block inside when" do
    input = """
    rule test {
      when FILE_CREATED {
        if [FILE::extension] eq "pdf" {
          log "found a pdf"
        }
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [if_block] = when_block.body
    assert %AST.If{} = if_block
    assert [%AST.Log{}] = if_block.body
  end

  test "parses nested if blocks" do
    input = """
    rule test {
      when FILE_CREATED {
        if [FILE::extension] eq "pdf" {
          let title = [PDF::title]
          let meta_title = [PDF::metadata title]
          if $title ne $meta_title {
            [PDF::metadata title $title]
          }
          [FILE::rename [STRING::slugify $title]]
        }
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [if_block] = when_block.body
    assert %AST.If{} = if_block
    # Should have: let, let, if, command = 4 statements
    assert length(if_block.body) == 4
  end

  test "parses multiple rules" do
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

    assert {:ok, %AST.Program{declarations: [_a, _b]}} = Parser.parse(input)
  end

  test "returns error for bad syntax" do
    input = "rule { }"
    assert {:error, message} = Parser.parse(input)
    assert is_binary(message)
  end

  test "parses garage-lights example file" do
    source = File.read!("priv/examples/garage-lights.rule")
    assert {:ok, %AST.Program{declarations: rules}} = Parser.parse(source)
    assert length(rules) == 2
    assert %AST.Rule{name: "garage-lights-on"} = Enum.at(rules, 0)
    assert %AST.Rule{name: "garage-lights-off"} = Enum.at(rules, 1)
  end

  # --- Condition declaration ---

  test "parses condition with when block" do
    input = """
    condition networkchanged {
      when NETWORK_CHANGED {
        log "changed"
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [cond_decl]}} = Parser.parse(input)
    assert %AST.Condition{name: "networkchanged"} = cond_decl
    assert [%AST.When{event: "NETWORK_CHANGED", body: [%AST.Log{}]}] = cond_decl.body
  end

  test "parses condition with compound event (OR)" do
    input = """
    condition networkchanged {
      when (INFRA::ip4_addr_changed OR INFRA::ip6_addr_changed) {
        log "ip changed"
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [cond_decl]}} = Parser.parse(input)
    assert %AST.Condition{name: "networkchanged"} = cond_decl
    [when_block] = cond_decl.body
    assert %AST.When{} = when_block
    # Event should be a structured compound expression
    assert {:compound, :or, ["INFRA::ip4_addr_changed", "INFRA::ip6_addr_changed"]} =
             when_block.event
  end

  # --- Capability declaration ---

  test "parses capability with context and on demand block" do
    input = """
    capability katachora-ddns-key {
      context infra.networking

      on demand {
        log "unlocking"
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [cap]}} = Parser.parse(input)
    assert %AST.Capability{name: "katachora-ddns-key"} = cap
    assert cap.context == "infra.networking"
    assert [%AST.Log{}] = cap.body
  end

  test "parses capability without context" do
    input = """
    capability simple-key {
      on demand {
        log "simple"
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [cap]}} = Parser.parse(input)
    assert %AST.Capability{name: "simple-key"} = cap
    assert cap.context == nil
    assert [%AST.Log{}] = cap.body
  end

  # --- Emit statement ---

  test "parses emit with command expression" do
    input = """
    rule test {
      when X {
        emit [EVENT::fire]
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [emit] = when_block.body
    assert %AST.Emit{value: %AST.Command{module: "EVENT", verb: "fire"}} = emit
    assert emit.type == nil
    assert emit.destination == nil
    assert emit.label == nil
  end

  test "parses emit with as label" do
    input = """
    rule test {
      when X {
        emit [EVENT::fire]
          as :my.label
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [emit] = when_block.body
    assert %AST.Emit{label: "my.label"} = emit
  end

  test "parses emit with type" do
    input = """
    rule test {
      when X {
        emit state [EVENT::fire]
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [emit] = when_block.body
    assert %AST.Emit{type: :state} = emit
  end

  # --- Demand statement ---

  test "parses demand statement" do
    input = """
    rule test {
      when X {
        demand katachora-ddns-key
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    [demand] = when_block.body
    assert %AST.Demand{capability: "katachora-ddns-key"} = demand
  end

  # --- When with MODULE::name event pattern ---

  test "parses when with MODULE::name event" do
    input = """
    rule test {
      when CONDITION::networkchanged {
        log "triggered"
      }
    }
    """

    assert {:ok, %AST.Program{declarations: [rule]}} = Parser.parse(input)
    [when_block] = rule.body
    assert %AST.When{event: "CONDITION::networkchanged"} = when_block
  end

  # --- Error path tests ---

  test "emit with no command expression returns error" do
    input = """
    rule test {
      when X {
        emit
      }
    }
    """

    assert {:error, msg} = Parser.parse(input)
    assert msg =~ "Expected command expression after emit"
  end

  test "demand with no name returns error" do
    input = """
    rule test {
      when X {
        demand
      }
    }
    """

    assert {:error, msg} = Parser.parse(input)
    assert msg =~ "Expected capability name after 'demand'"
  end

  test "capability missing on demand block returns error" do
    input = """
    capability broken {
      context infra.networking
    }
    """

    assert {:error, msg} = Parser.parse(input)
    assert msg =~ "Expected"
  end

  test "condition with empty body returns error" do
    input = """
    condition broken {
    }
    """

    assert {:error, msg} = Parser.parse(input)
    assert is_binary(msg)
  end

  # --- Full ddns example ---

  test "parses ddns example file" do
    source = File.read!("priv/examples/ddns.rule")
    assert {:ok, %AST.Program{declarations: declarations}} = Parser.parse(source)
    assert length(declarations) == 3

    [cap, cond_decl, rule] = declarations
    assert %AST.Capability{name: "katachora-ddns-key"} = cap
    assert %AST.Condition{name: "networkchanged"} = cond_decl
    assert %AST.Rule{name: "update-ddns"} = rule

    # Capability has context and on-demand body with emit
    assert cap.context == "infra.networking"
    assert [%AST.Emit{} = cap_emit] = cap.body
    assert %AST.Command{module: "SECRET", verb: "unlock"} = cap_emit.value
    assert cap_emit.label == "katachora.ddns.key"

    # Condition has when block with emit
    [when_block] = cond_decl.body
    assert %AST.When{} = when_block
    [cond_emit] = when_block.body
    assert %AST.Emit{} = cond_emit

    # Rule has context, when block with demand, lets, emit
    [context_node, when_block2] = rule.body
    assert %AST.Context{path: "infra.networking.dns"} = context_node
    assert %AST.When{event: "CONDITION::networkchanged"} = when_block2
    [demand | _rest] = when_block2.body
    assert %AST.Demand{capability: "katachora-ddns-key"} = demand
  end
end

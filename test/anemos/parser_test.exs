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
end

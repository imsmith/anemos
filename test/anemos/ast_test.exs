defmodule Anemos.ASTTest do
  use ExUnit.Case, async: true

  alias Anemos.AST

  test "program node wraps declarations" do
    node = %AST.Program{declarations: []}
    assert node.declarations == []
  end

  test "rule node has name, metadata, and body" do
    node = %AST.Rule{name: "garage-lights", body: [], meta: %{}}
    assert node.name == "garage-lights"
  end

  test "when block has event, duration, guard, and body" do
    node = %AST.When{event: "SENSOR_MOTION_DETECTED", duration: nil, guard: nil, body: []}
    assert node.event == "SENSOR_MOTION_DETECTED"
  end

  test "command expression has module, verb, and args" do
    node = %AST.Command{module: "DEVICE", verb: "set", args: ["garage.lights", "on"]}
    assert node.module == "DEVICE"
    assert node.verb == "set"
  end
end

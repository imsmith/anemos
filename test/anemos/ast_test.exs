defmodule Anemos.ASTTest do
  @moduledoc false
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

  test "DataDecl struct has all fields" do
    node = %Anemos.AST.DataDecl{
      name: "reserved-ips",
      source: nil,
      content: {:simple_list, ["10.0.0.0/8", "192.168.0.0/16"]},
      transclude: nil,
      scope: :global,
      line: 1
    }

    assert node.name == "reserved-ips"
    assert node.scope == :global
    assert {:simple_list, [_ | _]} = node.content
  end

  test "QueryDecl struct has all fields" do
    node = %Anemos.AST.QueryDecl{
      name: "wd-city",
      expect: [:city, :state],
      engine: "wikidata",
      body: "some query body",
      return: "?city",
      scope: :global,
      line: 1
    }

    assert node.name == "wd-city"
    assert node.expect == [:city, :state]
    assert node.engine == "wikidata"
    assert node.return == "?city"
  end
end

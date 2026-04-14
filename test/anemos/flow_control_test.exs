defmodule Anemos.FlowControlTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.AST

  test "Return struct has optional value" do
    node = %AST.Return{value: :expr, line: 1}
    assert node.value == :expr
  end

  test "Return struct defaults value to nil" do
    node = %AST.Return{line: 1}
    assert node.value == nil
  end

  test "Done struct has line" do
    node = %AST.Done{line: 1}
    assert node.line == 1
  end

  test "NextEvent struct has target and optional args" do
    node = %AST.NextEvent{target: "other-handler", args: %{}, line: 1}
    assert node.target == "other-handler"
  end

  test "NextRule struct has target and optional args" do
    node = %AST.NextRule{target: "other-rule", args: %{}, line: 1}
    assert node.target == "other-rule"
  end
end

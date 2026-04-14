defmodule Anemos.LoopTest do
  @moduledoc false
  use ExUnit.Case

  alias Anemos.AST

  test "While struct has condition and body" do
    node = %AST.While{condition: :cond, body: [:stmt], line: 1}
    assert node.condition == :cond
    assert node.body == [:stmt]
    assert node.line == 1
  end

  test "For struct has var, iterable, and body" do
    node = %AST.For{var: "x", iterable: :list, body: [:stmt], line: 1}
    assert node.var == "x"
    assert node.iterable == :list
    assert node.body == [:stmt]
  end
end

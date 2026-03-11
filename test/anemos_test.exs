defmodule AnemosTest do
  use ExUnit.Case
  doctest Anemos

  test "greets the world" do
    assert Anemos.hello() == :world
  end
end

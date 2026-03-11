defmodule AnemosTest do
  use ExUnit.Case

  test "run/2 requires :event option" do
    assert_raise KeyError, fn ->
      Anemos.run("rule x { when E { } }", [])
    end
  end
end

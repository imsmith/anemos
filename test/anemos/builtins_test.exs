defmodule Anemos.Runtime.BuiltinsTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.Builtins

  test "filter keeps elements where predicate is truthy" do
    collection = [1, 2, 3, 4, 5]
    predicate_fn = fn ctx, _bindings -> get_in(ctx, [:context_data, "x"]) > 3 end
    result = Builtins.filter(collection, "x", predicate_fn, %{}, %{})
    assert result == [4, 5]
  end

  test "filter with empty collection returns empty" do
    result = Builtins.filter([], "x", fn _, _ -> true end, %{}, %{})
    assert result == []
  end

  test "map transforms each element" do
    collection = [1, 2, 3]
    transform_fn = fn ctx, _bindings -> get_in(ctx, [:context_data, "x"]) * 10 end
    result = Builtins.map(collection, "x", transform_fn, %{}, %{})
    assert result == [10, 20, 30]
  end

  test "reduce accumulates over collection" do
    collection = [1, 2, 3, 4]

    body_fn = fn ctx, bindings ->
      Map.get(bindings, {:set, "total"}) + get_in(ctx, [:context_data, "x"])
    end

    result = Builtins.reduce(collection, "total", 0, "x", body_fn, %{}, %{})
    assert result == 10
  end

  test "reduce with empty collection returns initial value" do
    result = Builtins.reduce([], "acc", 42, "x", fn _, _ -> 0 end, %{}, %{})
    assert result == 42
  end

  test "emit calls command function for each element and returns collection" do
    collection = [1, 2, 3]
    test_pid = self()

    command_fn = fn element, _ctx, _bindings ->
      send(test_pid, {:emitted, element})
    end

    result = Builtins.emit(collection, command_fn, %{}, %{})
    assert result == [1, 2, 3]
    assert_received {:emitted, 1}
    assert_received {:emitted, 2}
    assert_received {:emitted, 3}
  end
end

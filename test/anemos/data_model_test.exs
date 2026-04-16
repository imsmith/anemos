defmodule Anemos.DataModelTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.DataModelRegistry

  defmodule TestHandler do
    @moduledoc false
    @behaviour Anemos.DataModel
    def keyword, do: "test-format"
    def parse(raw), do: {:ok, String.split(raw, "\n")}
    def eval(parsed, _context), do: {:ok, parsed}
    def transduce(_data, _shape, _transducer), do: {:error, :not_supported}
  end

  test "register and lookup a data model handler" do
    {:ok, registry} = DataModelRegistry.start_link()
    :ok = DataModelRegistry.register(registry, TestHandler)
    assert {:ok, TestHandler} = DataModelRegistry.lookup(registry, "test-format")
    assert :error = DataModelRegistry.lookup(registry, "unknown")
  end

  test "list returns registered keywords" do
    {:ok, registry} = DataModelRegistry.start_link()
    :ok = DataModelRegistry.register(registry, TestHandler)
    assert "test-format" in DataModelRegistry.list(registry)
  end
end

defmodule Anemos.Runtime.Modules.Device do
  @moduledoc """
  Stub DEVICE module for development and testing.

  All verbs echo back their inputs as `%{module: "DEVICE", verb: verb, args: args}`.
  Replace with a real implementation for production use.
  """

  use Anemos.Module, name: "DEVICE"

  verb :set, fn args, _ctx -> {:ok, %{module: "DEVICE", verb: "set", args: args}} end
  verb :get, fn args, _ctx -> {:ok, %{module: "DEVICE", verb: "get", args: args}} end
end

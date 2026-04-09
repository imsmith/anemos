defmodule Anemos.Runtime.Modules.File do
  @moduledoc """
  Stub FILE module for development and testing.

  All verbs echo back their inputs as `%{module: "FILE", verb: verb, args: args}`.
  Replace with a real implementation for production use.
  """

  use Anemos.Module, name: "FILE"

  verb :read, fn args, _ctx -> {:ok, %{module: "FILE", verb: "read", args: args}} end
  verb :write, fn args, _ctx -> {:ok, %{module: "FILE", verb: "write", args: args}} end
  verb :rename, fn args, _ctx -> {:ok, %{module: "FILE", verb: "rename", args: args}} end
  verb :extension, fn args, _ctx -> {:ok, %{module: "FILE", verb: "extension", args: args}} end
end

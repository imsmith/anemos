defmodule Anemos.Runtime.Modules.File do
  @moduledoc """
  Stub FILE module for v0.1.0.

  Returns operation maps without performing real file operations.
  """

  @behaviour Anemos.Runtime.Module

  @impl true
  def handle_verb(verb, args, _context) do
    {:ok, %{module: "FILE", verb: verb, args: args}}
  end
end

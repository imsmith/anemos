defmodule Anemos.Runtime.Modules.Device do
  @moduledoc """
  Stub DEVICE module for v0.1.0.

  Returns operation maps without performing real device actions.
  """

  @behaviour Anemos.Runtime.Module

  @impl true
  def handle_verb(verb, args, _context) do
    {:ok, %{module: "DEVICE", verb: verb, args: args}}
  end
end

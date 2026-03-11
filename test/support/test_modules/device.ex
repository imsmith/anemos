defmodule Anemos.TestModules.Device do
  @behaviour Anemos.Runtime.Module

  @impl true
  def handle_verb("set", args, _context) do
    {:ok, %{action: :set, args: args}}
  end
end

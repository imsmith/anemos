defmodule Anemos.TestModules.Device do
  @behaviour Anemos.Runtime.Module

  @impl true
  def handle_verb("set", args, _context) do
    {:ok, %{action: :set, args: args}}
  end

  @impl true
  def handle_verb(_verb, _args, _context) do
    {:error, :unknown_verb}
  end
end

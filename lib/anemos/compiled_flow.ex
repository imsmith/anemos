defmodule Anemos.CompiledFlow do
  @moduledoc """
  A compiled flow: its name and ordered steps. Each step names a rule and
  carries a closure that resolves its `with { }` block against the invoking
  dispatch's context, since a flow has no bindings of its own.
  """
  @enforce_keys [:name, :steps]
  defstruct [:name, :steps]

  @type step :: %{target: String.t(), args: (map() -> map() | nil)}

  @type t :: %__MODULE__{name: String.t(), steps: [step()]}
end

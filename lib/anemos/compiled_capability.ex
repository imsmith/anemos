defmodule Anemos.CompiledCapability do
  @moduledoc """
  A compiled capability: name, context scope, and handler closure for on-demand execution.
  """
  @enforce_keys [:name, :context, :handler]
  defstruct [:name, :context, :handler]

  @type t :: %__MODULE__{
          name: String.t(),
          context: String.t(),
          handler: (map() -> {:ok, list()} | {:error, term()})
        }
end

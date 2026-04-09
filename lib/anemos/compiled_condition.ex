defmodule Anemos.CompiledCondition do
  @moduledoc """
  A compiled condition: name, trigger subscriptions, evaluator function, and side effects.
  """
  @enforce_keys [:name, :subscriptions, :evaluator]
  defstruct [:name, :subscriptions, :evaluator, :side_effects, :side_effect_handler, :context]

  @type t :: %__MODULE__{
          name: String.t(),
          subscriptions: [String.t()],
          evaluator: (String.t(), map() -> boolean()),
          side_effects: list(),
          side_effect_handler: (-> {:ok, [map()]}) | nil,
          context: String.t() | nil
        }
end

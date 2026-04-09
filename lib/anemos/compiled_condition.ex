defmodule Anemos.CompiledCondition do
  @moduledoc """
  A compiled condition: name, trigger subscriptions, evaluator function, and side effects.
  """
  @enforce_keys [:name, :subscriptions, :evaluator]
  defstruct [:name, :subscriptions, :evaluator, :side_effects, :context]
end

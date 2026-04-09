defmodule Anemos.CompiledSchedule do
  @moduledoc """
  A compiled schedule: event name, time spec, recurrence, and handler.

  Produced by the compiler from `at` blocks. The scheduler uses these
  to set timers and dispatch synthetic `AT_*` events.
  """

  @enforce_keys [:event_name, :time_spec]
  defstruct [:event_name, :time_spec, :recurrence, :handler, :context]

  @type t :: %__MODULE__{
          event_name: String.t(),
          time_spec: {:time, {non_neg_integer(), non_neg_integer()}}
                   | {:date, {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
                   | {:day, atom()}
                   | {:interval, {non_neg_integer(), atom()}}
                   | {:delay_ms, non_neg_integer()},
          recurrence: atom() | nil,
          handler: (-> {:ok, [map()]}) | nil,
          context: String.t() | nil
        }
end

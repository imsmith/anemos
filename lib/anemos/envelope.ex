defmodule Anemos.Envelope do
  @moduledoc """
  Message envelope for emitted values.

  Every emit that targets a channel produces an envelope carrying
  the payload, metadata, and routing information specified by
  the language spec (section 10.3).
  """

  @enforce_keys [:payload]
  defstruct [
    :type,
    :payload,
    :source,
    :timestamp,
    :label,
    :channel
  ]

  @type t :: %__MODULE__{
          type: :state | :effect | :stream | nil,
          payload: term(),
          source: String.t() | nil,
          timestamp: DateTime.t() | nil,
          label: String.t() | nil,
          channel: String.t() | nil
        }
end

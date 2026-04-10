defmodule Anemos.Channel.Logger do
  @moduledoc """
  Default channel connector that logs emitted messages via `Logger.info/1`.

  Used when no connector is explicitly registered. Ensures emits to
  channels are never silent — they always produce observable output.
  """

  @behaviour Anemos.Channel

  require Logger

  @doc "Logs the envelope to the Elixir Logger."
  @impl true
  def publish(channel, envelope) do
    type = if envelope.type, do: " #{envelope.type}", else: ""
    label = if envelope.label, do: " as #{envelope.label}", else: ""
    Logger.info("[anemos]#{type} emit to #{channel}#{label}: #{inspect(envelope.payload)}")
    :ok
  end
end

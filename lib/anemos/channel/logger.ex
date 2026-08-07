defmodule Anemos.Channel.Logger do
  @moduledoc """
  Default channel connector that logs emitted messages via `Logger.info/1`.

  Used when no connector is explicitly registered. Ensures emits to
  channels are never silent — they always produce observable output.

  ## What is logged

  Routing metadata only: channel, envelope type, and label. The payload is
  described by shape (`binary(23 bytes)`, `map(2 keys)`) via
  `Anemos.Redact.summarize/1`, never by content.

  This connector is the default, so it runs in any deployment that has not
  registered its own. The spec's own `SECRET::unlock` example obtains a
  credential by emitting it; logging payload contents at `:info` would write
  that credential to the application log and onward to wherever logs ship.
  "Never silent" is not the same as "fully disclosed". A connector that needs
  the payload should be written deliberately — see `Anemos.Channel`.
  """

  @behaviour Anemos.Channel

  require Logger

  @doc "Logs the envelope's routing metadata and payload shape to the Elixir Logger."
  @impl true
  def publish(channel, envelope) do
    type = if envelope.type, do: " #{envelope.type}", else: ""
    label = if envelope.label, do: " as #{envelope.label}", else: ""

    Logger.info(
      "[anemos]#{type} emit to #{channel}#{label}: #{Anemos.Redact.summarize(envelope.payload)}"
    )

    :ok
  end
end

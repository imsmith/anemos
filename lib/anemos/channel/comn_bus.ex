defmodule Anemos.Channel.ComnBus do
  @moduledoc """
  Channel connector that publishes envelopes via `Comn.EventBus`.

  Subscribers receive `{:event, channel_path, %Anemos.Envelope{}}` messages.
  Requires `Comn.Supervisor` (or a Registry named `Comn.EventBus`) in the
  supervision tree.

  ## Usage

      Anemos.Runtime.connect(:anemos, Anemos.Channel.ComnBus)

      # In a subscriber process:
      Comn.EventBus.subscribe("sensors/temperature")
      receive do
        {:event, _topic, %Anemos.Envelope{} = env} -> handle(env)
      end

  """

  @behaviour Anemos.Channel

  @impl true
  def publish(channel, %Anemos.Envelope{} = envelope) do
    Comn.EventBus.broadcast(channel, envelope)
  end
end

defmodule Anemos.Channel do
  @moduledoc """
  Behaviour for channel connectors — the bridge between Anemos emit
  operations and the host app's messaging infrastructure.

  Implement this behaviour to route emitted messages through your
  system's PubSub, event bus, NATS, or any other messaging layer.

  ## Usage

      # In your app:
      @behaviour Anemos.Channel

      @impl true
      def publish(channel, envelope) do
        Phoenix.PubSub.broadcast(MyApp.PubSub, channel, {:anemos, envelope})
      end

  Register with the runtime:

      Anemos.Runtime.connect(:anemos, MyApp.PubSubChannel)

  ## Default

  If no connector is registered, `Anemos.Channel.Logger` is used —
  it logs emits via `Logger.info/1` so they're never silent.
  """

  @doc "Publish a message envelope to a named channel. Called when a rule executes `emit [X] to channel(path)`."
  @callback publish(channel :: String.t(), envelope :: Anemos.Envelope.t()) ::
              :ok | {:error, term()}
end

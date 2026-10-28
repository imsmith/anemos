# `Anemos.Channel`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/channel.ex#L1)

Behaviour for channel connectors — the bridge between Anemos emit
operations and the host app's messaging infrastructure.

Implement this behaviour to route emitted messages through your
system's event bus, NATS, AMQP, or any other messaging layer.

## Built-in connectors

  * `Anemos.Channel.ComnBus` — publishes via `Comn.EventBus` (Registry-based pub/sub)
  * `Anemos.Channel.Logger` — logs emits via `Logger.info/1` (default)

## Usage

    # Use the built-in Comn.EventBus connector:
    Anemos.Runtime.connect(:anemos, Anemos.Channel.ComnBus)

    # Or implement your own (see Anemos.Channel.Logger for a minimal example):
    # @behaviour Anemos.Channel
    # @impl true
    # def publish(channel, envelope), do: ...
    Anemos.Runtime.connect(:anemos, MyApp.NatsChannel)

## Default

If no connector is registered, `Anemos.Channel.Logger` is used —
it logs emits via `Logger.info/1` so they're never silent.

# `publish`

```elixir
@callback publish(channel :: String.t(), envelope :: Anemos.Envelope.t()) ::
  :ok | {:error, term()}
```

Publish a message envelope to a named channel. Called when a rule executes `emit [X] to channel(path)`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

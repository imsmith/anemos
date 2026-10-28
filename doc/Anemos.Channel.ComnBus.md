# `Anemos.Channel.ComnBus`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/channel/comn_bus.ex#L1)

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

---

*Consult [api-reference.md](api-reference.md) for complete listing*

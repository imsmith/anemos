# `Anemos.Envelope`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/envelope.ex#L1)

Message envelope for emitted values.

Every emit that targets a channel produces an envelope carrying
the payload, metadata, and routing information specified by
the language spec (section 10.3).

# `t`

```elixir
@type t() :: %Anemos.Envelope{
  channel: String.t() | nil,
  label: String.t() | nil,
  payload: term(),
  signature: binary() | nil,
  source: String.t() | nil,
  timestamp: DateTime.t() | nil,
  type: :state | :effect | :stream | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.Subscribable`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/subscribable.ex#L1)

Behaviour for data sources that support dynamic subscription.

Implementations register a protocol identifier (e.g., "webhook",
"rss", "amqp") used in `dynamic { subscribe <protocol> <uri> }` blocks.

The adapter owns the feed's lifecycle, including any polling. A source
that has to be pulled on a cadence starts its own timer inside
`subscribe/3` and calls the callback on each pull; the policy language
has no vocabulary for that cadence, by design. If the cadence should be
visible in the policy, write an `at interval(...)` rule that asks the
host to refresh — see the manual, chapter 7.

# `subscribe`

```elixir
@callback subscribe(protocol :: String.t(), uri :: String.t(), callback :: fun()) ::
  {:ok, reference()} | {:error, atom()}
```

Subscribes to the given URI using the named protocol. Returns `{:ok, ref}` on success or `{:error, reason}` on failure.

# `unsubscribe`

```elixir
@callback unsubscribe(ref :: reference()) :: :ok
```

Cancels an active subscription identified by `ref`. Always returns `:ok`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

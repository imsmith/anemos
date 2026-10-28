# `Anemos.Subscribable`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/subscribable.ex#L1)

Behaviour for data sources that support dynamic subscription.

Implementations register a protocol identifier (e.g., "webhook",
"rss", "amqp") used in `dynamic { subscribe <protocol> <uri> }` blocks.

# `interval`

```elixir
@callback interval(spec :: String.t()) :: pos_integer()
```

Converts a human-readable interval spec (e.g., `"5m"`) to milliseconds.

# `periodic?`

```elixir
@callback periodic?() :: boolean()
```

Returns `true` if this source is polled on a schedule rather than push-based.

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

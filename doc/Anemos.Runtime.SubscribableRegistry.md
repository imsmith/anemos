# `Anemos.Runtime.SubscribableRegistry`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/subscribable_registry.ex#L1)

Agent mapping protocol strings to `Anemos.Subscribable` handler modules.

This registry is a companion to `Anemos.Runtime.DataModelRegistry`, not a
replacement for it. The two key different things for different behaviours:
this one maps a *protocol* (`"webhook"`, `"rss"`, `"amqp"`) to an
`Anemos.Subscribable` handler for `dynamic { subscribe ... }` blocks;
`DataModelRegistry` maps a *format keyword* (`"edn"`, `"xml"`, `"sql"`) to an
`Anemos.DataModel` handler for format bodies and query engines. One handler
module may implement both behaviours and appear in both registries.

The registration signature differs for the same reason. `DataModelRegistry`
derives its key from the handler via `keyword/0`, because a format handler
owns its format. Here the protocol string is supplied externally at
registration time, because `Subscribable` handlers receive the protocol as a
parameter and so may serve more than one.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `list`

```elixir
@spec list(pid() | atom()) :: [String.t()]
```

Returns all registered protocol strings.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.SubscribableRegistry.start_link()
    iex> Anemos.Runtime.SubscribableRegistry.list(reg)
    []

# `lookup`

```elixir
@spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
```

Looks up a handler module by protocol string.

Returns `{:ok, module}` or `:error`.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.SubscribableRegistry.start_link()
    iex> Anemos.Runtime.SubscribableRegistry.lookup(reg, "missing")
    :error

# `register`

```elixir
@spec register(pid() | atom(), String.t(), module()) :: :ok
```

Registers a handler module under the given protocol string.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.SubscribableRegistry.start_link()
    iex> Anemos.Runtime.SubscribableRegistry.register(reg, "webhook", MyHandler)
    :ok

# `start_link`

```elixir
@spec start_link(keyword()) :: Agent.on_start()
```

Starts a subscribable registry.

## Options

  * `:name` — process registration name (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*

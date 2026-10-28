# `Anemos.Runtime.DataModelRegistry`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/data_model_registry.ex#L1)

Agent mapping data model keyword strings to handler modules.

Handler modules must implement the `Anemos.DataModel` behaviour and
expose a `keyword/0` function that returns their format identifier.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `list`

```elixir
@spec list(pid() | atom()) :: [String.t()]
```

Returns all registered keyword strings.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.DataModelRegistry.start_link()
    iex> Anemos.Runtime.DataModelRegistry.list(reg)
    []

# `lookup`

```elixir
@spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
```

Looks up a handler module by keyword string.

Returns `{:ok, module}` or `:error`.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.DataModelRegistry.start_link()
    iex> Anemos.Runtime.DataModelRegistry.lookup(reg, "missing")
    :error

# `register`

```elixir
@spec register(pid() | atom(), module()) :: :ok
```

Registers a handler module under its own keyword.

The module must implement `Anemos.DataModel` and return a keyword from `keyword/0`.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.DataModelRegistry.start_link()
    iex> Anemos.Runtime.DataModelRegistry.register(reg, MyHandler)
    :ok

# `start_link`

```elixir
@spec start_link(keyword()) :: Agent.on_start()
```

Starts a data model registry.

## Options

  * `:name` — process registration name (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*

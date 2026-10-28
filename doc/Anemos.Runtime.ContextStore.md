# `Anemos.Runtime.ContextStore`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/context_store.ex#L1)

Agent holding external key-value context data.
Keys are dotted paths (e.g., "infra.networking.dns.fqdn").
Resolution joins the context path with the variable name to form the lookup key.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `put`

```elixir
@spec put(pid() | atom(), String.t(), term()) :: :ok
```

Stores a key-value pair.

# `resolve`

```elixir
@spec resolve(pid() | atom(), String.t(), String.t()) :: {:ok, term()} | :error
```

Resolves a variable name against a context path.

Joins the context path and name with `.` to form the full key,
then looks it up in the store.

## Examples

    iex> {:ok, store} = Anemos.Runtime.ContextStore.start_link(data: [{"infra.dns.fqdn", "host.example.tld"}])
    iex> Anemos.Runtime.ContextStore.resolve(store, "infra.dns", "fqdn")
    {:ok, "host.example.tld"}

    iex> {:ok, store} = Anemos.Runtime.ContextStore.start_link([])
    iex> Anemos.Runtime.ContextStore.resolve(store, "infra", "missing")
    :error

# `start_link`

Starts a context store.

## Options

  * `:data` — initial key-value pairs as a list of `{key, value}` tuples (optional)
  * `:name` — process registration name (optional)
  * `:state_table` — an `Anemos.Runtime.StateTable` the data is kept in,
    so that this process restarting does not lose it (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.Runtime.DataStore`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/data_store.ex#L1)

GenServer holding named datasets for data blocks.

Entries are keyed by `{name, scope_tag}` where `scope_tag` is `:global`
or `{:local, discriminator}`. Local entries shadow global entries in every
lookup.

## What a scope discriminator is

Any term. It is *not* required to be a pid, and in the interpreter it
usually is not: rules do not run as separate processes — every rule body
executes inside the dispatcher — so a pid discriminator would collapse
every rule's inline `data` block into one scope. `Anemos.Runtime.Dispatcher`
therefore scopes rule-local blocks by rule *name*, and the compiled
`memberof()` closure passes the same rule name as `:scope_hint`.

Every lookup takes that hint the same way. `get/3` previously hardcoded
`self()` while `member?/4` and `member_any?/4` honoured a `:scope_hint`,
so `get` could not reach a rule-scoped entry at all — two lookup functions
with two different scope models (A-24). The hint defaults to `self()`,
which is what a host process registering data for itself wants.

## Cleanup

Two paths, because only one of them can exist for a given discriminator:

  * **pid discriminators are monitored.** When the process dies, every
    entry scoped to it is removed. This is automatic and needs no caller.

  * **every other discriminator must be dropped explicitly**, with
    `drop_scope/2` or `deregister/3`. There is no process to watch, so
    there is nothing to make cleanup automatic — an unloaded policy's
    rule-scoped entries persist until something says to remove them, and
    before `drop_scope/2` existed nothing could. Reloading a policy
    re-registered under the same key, so entries did not multiply, but
    they also never went away.

## Registering a dataset

    DataStore.register(store, "reserved-ips", :global,
      MapSet.new(["10.0.0.0/8", "192.168.0.0/16"]))

## Membership check (caller's local scope shadows global)

    DataStore.member?(store, "reserved-ips", "10.0.0.0/8")
    # => true

## Union membership across multiple sets

    DataStore.member_any?(store, ["blocklist", "denylist"], ip)

## Fetch full dataset

    DataStore.get(store, "reserved-ips")
    # => %MapSet{...}

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `deregister`

```elixir
@spec deregister(GenServer.server(), String.t(), term()) :: :ok
```

Removes a named entry for the given scope.

# `drop_scope`

```elixir
@spec drop_scope(GenServer.server(), term()) :: :ok
```

Removes every entry registered under `scope_tag`.

This is the cleanup path for scopes that cannot be monitored — a rule
name, or any other non-pid discriminator. Idempotent.

# `get`

```elixir
@spec get(GenServer.server(), String.t(), keyword()) :: term() | nil
```

Returns the full dataset for `name`, or `nil` if not found.

Checks local scope first (by `scope_hint` if provided, otherwise `self()`),
then global — the same resolution `member?/4` performs.

# `member?`

```elixir
@spec member?(GenServer.server(), String.t(), term(), keyword()) :: boolean()
```

Returns true if `value` is a member of the named dataset.

Checks local scope first (by `scope_hint` if provided, otherwise `self()`),
then global. `get/3` resolves scope identically.

# `member_any?`

```elixir
@spec member_any?(GenServer.server(), [String.t()], term(), keyword()) :: boolean()
```

Returns true if `value` is a member of any of the named datasets.

# `register`

```elixir
@spec register(GenServer.server(), String.t(), term(), term(), keyword()) :: :ok
```

Registers (or replaces) a named dataset under a scope tag.

`scope_tag` is `:global` or `{:local, discriminator}` — see the moduledoc
for what may be a discriminator and how each kind is cleaned up.

## Options

  * `:source` — string describing origin
  * `:transcluded` — transcluded ref term
  * `:subscription` — monitor ref for live feeds

# `start_link`

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

Starts a DataStore process.

## Options

  * `:name` — optional registration name

# `update`

```elixir
@spec update(GenServer.server(), String.t(), term(), term()) :: :ok
```

Replaces the dataset for an existing entry. Used by subscription callbacks.

No-op if the entry does not exist.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

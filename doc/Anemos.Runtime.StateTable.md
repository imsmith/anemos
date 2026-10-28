# `Anemos.Runtime.StateTable`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/state_table.ex#L1)

Where a runtime keeps what its processes have accumulated, so that the
restart of one of them does not lose it.

`Anemos.Runtime.PolicyStore` holds what was *loaded*. This holds what has
*happened* since: `set` bindings and armed dwell timers (A-40, A-41), each
condition's boolean (A-42), and the module registrations (A-43).

It is an ETS table owned by the runtime's supervisor process. Every child
that writes to it can crash and be restarted without the table going
anywhere; it dies only with the runtime itself. A process could not do
this job: the module registry is already a process, and a second one
behind it would just move the question.

The table is public, because its writers are the supervisor's children.
That grants nothing new — everything in it was already reachable by
calling the process that held it, under a name just as public.

Every function accepts `nil` for the table and does nothing, so a
dispatcher, registry or condition server started on its own, outside an
`Anemos.Runtime`, works as before and simply keeps no durable state.

It does not survive the node. Persisting it to disk is a separate
decision — a `set` binding can hold an `Anemos.Secret`.

# `t`

```elixir
@type t() :: :ets.table() | nil
```

# `delete`

```elixir
@spec delete(t(), term()) :: :ok
```

# `get`

```elixir
@spec get(t(), term(), term()) :: term()
```

# `name_for`

```elixir
@spec name_for(atom()) :: atom()
```

The table of the runtime `runtime`.

# `new`

```elixir
@spec new(atom()) :: :ets.table()
```

Creates the table. Call from the process that should own it.

# `push`

```elixir
@spec push(t(), atom(), term(), pos_integer()) :: :ok
```

Appends `entry` to the bounded log `kind`, dropping the oldest once there
are more than `limit`.

# `put`

```elixir
@spec put(t(), term(), term()) :: :ok
```

# `recent`

```elixir
@spec recent(t(), atom(), pos_integer()) :: [term()]
```

The newest `limit` entries of the log `kind`, newest first.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

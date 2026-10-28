# `Anemos.Runtime.PolicyStore`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/policy_store.ex#L1)

Durable record of everything that has been loaded into a runtime.

The dispatcher holds a *derived* view — a rule index, a set of condition
servers, a set of capability servers. That view is disposable. This store
holds the source it is derived from, so that a dispatcher which crashes
and is restarted by its supervisor can rebuild rather than come back
blank.

Without it, re-parenting the dispatcher's children (see
`Anemos.Runtime.StoreSupervisor`) only narrows the window: any *other*
dispatcher crash still produced a restarted dispatcher with `rules: []`,
and `dispatch/3` then returned `{:ok, []}` forever — byte-identical to
"no rule matched".

It also holds the channel connector, which is set through the dispatcher
at runtime and would otherwise silently revert to the default on restart.

# `entry`

```elixir
@type entry() :: %{
  id: String.t() | nil,
  compiled: Anemos.CompilationResult.t(),
  fingerprints: %{optional({:rule | :condition, String.t()}) =&gt; binary()}
}
```

One loaded policy. `id` is `nil` for a load that named no policy.
`fingerprints` maps `{:rule | :condition, name}` to a digest of the
declaration's text, which is how a deploy tells an edited declaration from
one that merely sits in an edited file.

# `all`

```elixir
@spec all(Agent.agent()) :: [Anemos.CompilationResult.t()]
```

Returns every loaded compilation result in load order.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `connector`

```elixir
@spec connector(Agent.agent()) :: module()
```

Returns the recorded channel connector.

# `delete`

```elixir
@spec delete(Agent.agent(), String.t()) :: :ok
```

Forgets the policy `id`.

# `drop_rules`

```elixir
@spec drop_rules(Agent.agent(), [String.t()]) :: :ok
```

Removes the named rules from every stored compilation result.

This is what makes `Anemos.Runtime.Dispatcher.unload/2` durable. The
dispatcher's rule list is derived and rebuilt from this store on restart,
so an unload that touched only the derived view would be undone by the
next dispatcher crash — the rule would come back.

Only rules are removed. A compilation result also carries conditions,
capabilities and data blocks, which are not owned by any one rule and are
not implied by unloading one. A result left with no rules is kept for the
same reason.

# `entries`

```elixir
@spec entries(Agent.agent()) :: [entry()]
```

Every loaded policy in load order, with its identity.

# `put`

```elixir
@spec put(Agent.agent(), Anemos.CompilationResult.t()) :: :ok
```

Appends a compilation result. Load order is preserved — rebuilding replays
it, so later policies shadow earlier ones exactly as they did on first load.

# `put`

```elixir
@spec put(Agent.agent(), String.t(), Anemos.CompilationResult.t(), map()) :: :ok
```

Records `compiled` as the policy `id`, in place of whatever was recorded
under that id. The policy moves to the end of the load order, which is
where its rules go in the dispatcher's live list when they are replaced.

# `put_connector`

```elixir
@spec put_connector(Agent.agent(), module()) :: :ok
```

Records the channel connector so it survives a dispatcher restart.

# `start_link`

```elixir
@spec start_link(keyword()) :: Agent.on_start()
```

Starts a policy store.

## Options

  * `:name` — process registration name (optional)
  * `:state_table` — an `Anemos.Runtime.StateTable` the record is kept
    in. This store survives a dispatcher crash on its own; the table is
    what lets it survive its *own* restart, which the supervisor forces
    whenever a child ahead of it — the module registry, say — dies
    (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*

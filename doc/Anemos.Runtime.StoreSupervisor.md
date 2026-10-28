# `Anemos.Runtime.StoreSupervisor`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/store_supervisor.ex#L1)

Supervisor for stores-as-infrastructure.

Owns every process the dispatcher reads from or writes to but does not
itself represent: the `TripleStore`, the `DataStore`, the
`SubscribableRegistry`, and one `ConditionServer` / `CapabilityServer`
per declaration in the loaded policy set.

These processes were previously `start_link`ed from inside
the dispatcher's initialization callback. Because the dispatcher does not trap
exits, the death of any one of them killed the dispatcher, and the
dispatcher's own restart came back with an empty rule set — silently
destroying every loaded policy. Re-parenting them here severs that link:
a store crash is now a local, recoverable event.

## Resolution, not caching

Children are addressed by supervisor child id, never by cached pid:

  * `:triple_store`, `:data_store`, `:subscribable_registry`
  * `{:condition, name}`, `{:capability, name}`

`whereis/2` and `snapshot/1` read the live child list, so a restarted
child is picked up on the next dispatch rather than leaving the caller
holding a dead pid. The cost is one supervisor call per dispatch cycle,
which is cheap next to the rule bodies it precedes.

## Restart strategy

`:one_for_one` — the children are mutually independent. A `TripleStore`
crash tells you nothing about the `DataStore`, and restarting healthy
stores would discard state for no reason.

Every child is `:permanent`. All of them are infrastructure the runtime
needs in order to interpret a policy at all; none has a "finished
normally" state. Restarted stores come back empty, which is the correct
safe default: a condition that has lost its history reads `false`, and a
data block that has lost its dataset reports no members.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `delete`

```elixir
@spec delete(Supervisor.supervisor(), {:condition | :capability, String.t()}) :: :ok
```

Stops and forgets the server for a condition or capability that is no
longer declared. Idempotent.

# `put_capability`

```elixir
@spec put_capability(Supervisor.supervisor(), map()) ::
  {:ok, pid()} | {:error, term()}
```

Starts (or replaces) the capability server for a compiled capability.

# `put_condition`

```elixir
@spec put_condition(
  Supervisor.supervisor(),
  map(),
  (String.t() -&gt; any()),
  (String.t(), [map()] -&gt; any()) | nil,
  Anemos.Runtime.StateTable.t()
) :: {:ok, pid()} | {:error, term()}
```

Starts (or replaces) the condition server for a compiled condition.

Replacement rather than reuse is deliberate: `on_transition` closes over
the dispatcher pid, so a dispatcher that has just restarted must install
callbacks pointing at itself. The condition's boolean state resets to
`false` in the process, which is the safe reading.

`on_side_effects` is the second such callback, and it exists for the same
reason `on_transition` does: the condition server can compute a body's
operations but cannot execute one — routing an `emit` or a `[MOD::verb]`
is the dispatcher's job. Omitting it leaves the operations dropped, which
is what A-50 was.

# `snapshot`

```elixir
@spec snapshot(Supervisor.supervisor()) :: map()
```

Reads the whole child list in one call and shapes it for the dispatcher.

Returns `%{triple_store: pid, data_store: pid, subscribable_registry: pid,
conditions: %{name => pid}, capabilities: %{name => pid}}`. Any child that
is mid-restart appears as `nil` (infrastructure) or is simply absent from
the maps.

# `start_link`

Starts the store supervisor.

## Options

  * `:name` — process registration name (optional)

# `whereis`

```elixir
@spec whereis(Supervisor.supervisor(), term()) :: pid() | nil
```

Returns the live pid for a child id, or `nil` if it is absent or restarting.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

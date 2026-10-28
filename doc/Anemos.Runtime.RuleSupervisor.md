# `Anemos.Runtime.RuleSupervisor`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/rule_supervisor.ex#L1)

Second supervision tier: rule-scoped processes.

`Anemos.Runtime.StoreSupervisor` holds everything whose lifetime is the
runtime's. This supervisor holds everything whose lifetime is a *rule's*.
The distinction matters on failure: a rule-scoped store that dies should
take down that rule's scope and nothing else, whereas a shared store
coming back empty affects every rule at once.

## What actually runs here

Nothing, until a rule needs it.

`ensure_scope/2` starts a child `Supervisor` for one named rule and
returns its pid; a second call for the same rule returns the same pid
without starting anything. Rules that consume only shared infrastructure
— which, in the current interpreter, is all of them — never cause a child
to be started. `scope/2` returns `nil` for such a rule rather than
creating one on read.

This replaces the previous moduledoc claim that the module was "ready to
supervise per-rule GenServers": it was an empty `DynamicSupervisor` that
nothing started children in and nothing resolved children from.

## Restart strategy

`:one_for_one` at this tier — rule scopes are independent of one another,
and one policy's failure must not restart another policy's state.

Each per-rule scope is `:transient`: it is restarted if it crashes, but a
scope that is deliberately torn down by `stop_scope/2` (policy unloaded)
stays down.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `ensure_scope`

```elixir
@spec ensure_scope(Supervisor.supervisor(), String.t()) ::
  {:ok, pid()} | {:error, term()}
```

Returns the scope supervisor for `rule_name`, starting it if absent.

The returned pid is a plain `Supervisor` with no children; rule-scoped
stores are added to it with `Supervisor.start_child/2`.

# `scope`

```elixir
@spec scope(Supervisor.supervisor(), String.t()) :: pid() | nil
```

Returns the scope supervisor for `rule_name`, or `nil` if the rule has
never needed one. Never starts anything.

# `scopes`

```elixir
@spec scopes(Supervisor.supervisor()) :: [{String.t(), pid()}]
```

Returns `[{rule_name, pid}]` for every live rule scope.

# `start_link`

Starts the rule supervisor.

## Options

  * `:name` — process registration name (defaults to `__MODULE__`)

# `stop_scope`

```elixir
@spec stop_scope(Supervisor.supervisor(), String.t()) :: :ok
```

Tears down a rule's scope and everything in it. Idempotent.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

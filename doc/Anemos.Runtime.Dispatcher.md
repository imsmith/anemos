# `Anemos.Runtime.Dispatcher`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/dispatcher.ex#L1)

GenServer holding compiled rules indexed by subscription.

Dispatches events to matching rules, executes resulting operations
via the ModuleRegistry. Also routes synthetic `CONDITION_<name>` events
when conditions transition.

Handled operation types: `:command`, `:log`, `:emit`, `:demand`,
`:assert_triple`, `:triple_query`, `:nextevent`, `:nextrule`.

## Owns no process lifecycles

The dispatcher `start_link`s nothing. Condition servers, capability
servers, the triple store, the data store and the subscribable registry
all live under `Anemos.Runtime.StoreSupervisor`, and are resolved by
child id at the head of every callback (`refresh_stores/1`). The
dispatcher's own state is a *derived* view, rebuildable at any moment
from `Anemos.Runtime.PolicyStore` — which is what `init/1` does, so that
a crash costs a dispatch cycle rather than every loaded policy.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `condition_state`

```elixir
@spec condition_state(pid() | atom(), String.t()) :: boolean() | nil
```

Returns the current boolean state of a named condition, or `nil` if not found.

# `data_member?`

```elixir
@spec data_member?(pid() | atom(), String.t(), term()) :: boolean()
```

Returns true if `value` is a member of the named data block dataset.

# `deploy`

```elixir
@spec deploy(pid() | atom(), String.t(), Anemos.CompilationResult.t(), map()) ::
  :ok
  | {:error, [Comn.Errors.ErrorStruct.t()]}
  | {:refused, Comn.Errors.ErrorStruct.t()}
```

Deploys `compiled` as the policy `id`, over whatever was last deployed
under that id.

Afterwards the dispatcher holds what `compiled` declares and nothing the
previous version declared that it does not. A rule or condition whose
fingerprint is unchanged keeps its state; see the `{:deploy, ...}`
callback.

Answers what `load/2` would. A policy that declares a name another policy
holds is not loaded at all: `{:refused, error}`.

Schedules are not touched: the scheduler is not the dispatcher's to call.
The caller follows with `Anemos.Runtime.Scheduler.sync/1`.

# `describe`

```elixir
@spec describe(pid() | atom()) :: map()
```

See `Anemos.Runtime.describe/1`. Everything but schedules and modules.

# `dispatch`

```elixir
@spec dispatch(pid() | atom(), String.t(), map(), timeout()) :: list()
```

Dispatches an event to all matching rules and conditions.

Returns a list of `{:ok, operation}` or `{:error, reason}` tuples.

# `explain`

```elixir
@spec explain(pid() | atom(), String.t(), map(), timeout()) :: map()
```

See `Anemos.Runtime.explain/3`.

# `interact`

```elixir
@spec interact(pid() | atom(), String.t(), map(), timeout()) :: list()
```

Raises an interaction, already named by `Anemos.Runtime.Interaction.event_name/1`,
into the `on` blocks that take it. Same result shape as `dispatch/4`.

# `invoke_verb`

```elixir
@spec invoke_verb(GenServer.server() | nil, String.t(), String.t(), list(), map()) ::
  Anemos.Runtime.Module.verb_result()
```

Resolves `mod_name` in `registry`, validates `args`, and invokes `verb`.

**This is the only path from a `[MODULE::verb]` call to host code**, and
it is deliberately public so that it can be shared rather than copied.
Both positions the language offers go through it:

  * statement position — `execute_op/4`, on the operation list a rule
    handler returned;
  * expression position — `Anemos.Compiler`, from inside the compiled
    closure, where the call's return value becomes the value of the
    expression (A-56).

Sharing it is the point. A second implementation would be the fourth
instance of the defect shape A-39, A-59 and the duplicated `gate/3` all
had: a caller reaching the same destination by a path that skipped a
check. Here the checks are `Anemos.Runtime.Module.schema_for/2`, the
`Anemos.Runtime.ArgSchema` bounds and allow-lists, and
`Anemos.Runtime.PathGuard` confinement — all of them A-11's, and all of
them applied before `handle_verb/3` regardless of which position the call
was written in.

`context` is the *verb* context — the event context stamped with
`:_rule_source`. It is not the closure's evaluation context: `:data_store`
and `:registry` reach the closure and must not reach host verb code. See
`verb_context/2`.

A `nil` registry answers `unknown_module` rather than raising. A compiled
closure invoked outside a dispatcher — a unit test, an embedder calling
`handler.(event, %{}, %{})` directly — has no registry to be given, so
this is a reachable state and it fails closed with a message that says why
rather than resolving to `nil` and letting a guard read false.

# `load`

```elixir
@spec load(pid() | atom(), Anemos.CompilationResult.t()) ::
  :ok
  | {:error, [Comn.Errors.ErrorStruct.t()]}
  | {:refused, Comn.Errors.ErrorStruct.t()}
```

Loads compiled rules, conditions, and capabilities into a running dispatcher.

Declarations from different policies accumulate. A rule name that is
already loaded is **replaced**, not appended — see the `{:load, _}`
callback for why replacement rather than rejection.

A name held by a policy deployed under an identity is not replaced: the
load is refused whole, `{:refused, error}`.

# `policies`

```elixir
@spec policies(pid() | atom()) :: [map()]
```

The loaded policies in load order, each with the names it declares. A load
that named no policy has `id: nil`.

# `register_data_model`

```elixir
@spec register_data_model(pid() | atom(), module()) :: :ok
```

Registers an `Anemos.DataModel` handler under the keyword it answers from
`keyword/0`. That keyword then names a format in a `data` block and an
engine in a `query` block.

# `register_subscribable`

```elixir
@spec register_subscribable(pid() | atom(), String.t(), module()) :: :ok
```

Registers a `Subscribable` handler module for the given protocol string.

# `rules`

```elixir
@spec rules(pid() | atom()) :: [String.t()]
```

Returns the names of the rules currently loaded, without duplicates.

A rule with several `when` blocks compiles to several rules sharing one
name and is reported once.

# `start_link`

Starts a dispatcher.

## Options

  * `:registry` — pid or name of a `ModuleRegistry` (required)
  * `:store_supervisor` — pid or name of a `StoreSupervisor` (required)
  * `:policy_store` — pid or name of a `PolicyStore` (required)
  * `:rule_supervisor` — pid or name of a `RuleSupervisor` (optional)
  * `:runtime` — the `Anemos.Runtime` name, handed to host verbs as
    `:_runtime` so a verb can address the runtime it runs in (optional)
  * `:name` — process registration name (optional)

Rules, conditions and capabilities are *not* passed here. They are read
from the policy store, which is the only thing that survives a restart.
Use `Anemos.Runtime.Standalone.start_link/1` to wire up a dispatcher and
its stores outside a full `Anemos.Runtime` tree.

# `topology`

```elixir
@spec topology(pid() | atom()) :: %{store_supervisor: pid(), policy_store: pid()}
```

Returns the store supervisor and policy store this dispatcher reads from.

# `undeploy`

```elixir
@spec undeploy(pid() | atom(), String.t()) :: :ok | {:error, :not_loaded}
```

Removes the policy `id` and everything it declared.

# `unload`

```elixir
@spec unload(pid() | atom(), [String.t()]) :: :ok
```

Unloads the named rules.

Removes them from the rule set and the index, cancels any dwell timer they
have armed, drops their rule-scoped data blocks, and removes them from the
policy store so a dispatcher restart does not bring them back. Rule names
that are not loaded are ignored.

Rules only. Conditions, capabilities and global data blocks are not owned
by a rule — a policy-level unload would need a policy identity, which
`Anemos.CompilationResult` does not carry.

# `verb_context`

```elixir
@spec verb_context(map(), {String.t(), String.t() | nil}) :: map()
```

Builds the context a host verb sees: the event context plus `:_rule_source`,
`:_runtime` (the runtime's name, when run under one) and, added at the
call, `:_module` (the name the verb was addressed by).

One definition, used by `run_ops/5` for statement-position calls and by
`dispatch_immediate/6` to precompute `:_verb_context` for expression-position
ones, so the two positions cannot drift into showing host code different
things. Note what it does *not* add: `:data_store` and `:registry` are
closure-evaluation authority and stop at the closure.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

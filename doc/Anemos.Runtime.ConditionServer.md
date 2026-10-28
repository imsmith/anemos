# `Anemos.Runtime.ConditionServer`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/condition_server.ex#L1)

GenServer for a single named condition.
Holds boolean state. Evaluates incoming events against trigger logic.
Broadcasts `CONDITION_<name>` on false->true transition.
Queryable for current state at any time.

On a false->true transition the condition body's side effects run and yield a
list of operations. Those operations only go somewhere if an `:on_side_effects`
callback was supplied — nothing here can execute a `:command` or route an
`:emit`, which is the dispatcher's job. Without the callback they are dropped.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `get_state`

```elixir
@spec get_state(pid() | atom()) :: boolean()
```

Returns the current boolean state of the condition.

## Examples

    iex> {:ok, pid} = Anemos.Runtime.ConditionServer.start_link(name_str: "test", subscriptions: ["EV"], evaluator: fn _, _ -> true end)
    iex> Anemos.Runtime.ConditionServer.get_state(pid)
    false

# `handle_event`

```elixir
@spec handle_event(pid() | atom(), String.t(), map()) :: :ok
```

Sends an event to the condition server for evaluation.

If the event matches a subscription and the evaluator returns `true`,
the condition transitions to true. Only false->true transitions trigger
the `on_transition` callback.

# `start_link`

Starts a condition server.

## Options

  * `:name_str` — the condition name (required)
  * `:subscriptions` — list of event names this condition listens to (required)
  * `:evaluator` — 2-arity function `(event_name, context) -> boolean` (required)
  * `:side_effects` — AST nodes to evaluate on transition (optional)
  * `:side_effect_handler` — function called on false->true (optional). The
    compiler produces a 1-arity function taking the triggering event context;
    a 0-arity function is also accepted.
  * `:on_side_effects` — callback `(name, [operation]) -> any` receiving the
    operations the side-effect handler produced (optional). Without it the
    operations are discarded — see the moduledoc.
  * `:on_transition` — callback `(name) -> any` called on false->true (optional)
  * `:name` — process registration name (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*

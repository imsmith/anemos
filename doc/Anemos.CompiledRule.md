# `Anemos.CompiledRule`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiler.ex#L1)

A compiled rule: name, event subscriptions, handler closure, and optional dwell duration.

The handler takes `(event_name, context, persistent_bindings)` and returns
`{:ok, [operation], updated_persistent_bindings}`. Persistent bindings hold
`set` values that survive across firings.

When `dwell_duration_ms` is non-nil, the rule is dispatched through the
Dispatcher's dwell-timer state machine instead of being fired immediately.
See `Anemos.Runtime.Dispatcher` for the state-machine semantics.

`trigger` is non-nil for a compound `when (A AND B)` / `when (A OR B)`:
the operator, the operand events, and the index of the `when` block within
its rule, which keys the reports the dispatcher keeps for it. See
`Anemos.Runtime.Report`.

# `t`

```elixir
@type t() :: %Anemos.CompiledRule{
  dwell_duration_ms: pos_integer() | nil,
  handler: (String.t(), map(), map() -&gt; {:ok, [map()], map()}),
  meta: map() | nil,
  name: String.t(),
  subscriptions: [String.t()],
  trigger: {:and | :or, [String.t()], non_neg_integer()} | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

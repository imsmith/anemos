# `Anemos.CompiledCondition`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiled_condition.ex#L1)

A compiled condition: name, trigger subscriptions, evaluator function, and side effects.

# `t`

```elixir
@type t() :: %Anemos.CompiledCondition{
  context: String.t() | nil,
  evaluator: (String.t(), map() -&gt; boolean()),
  name: String.t(),
  side_effect_handler: (map() -&gt; {:ok, [map()]}) | nil,
  side_effects: list(),
  subscriptions: [String.t()]
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.At`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L110)

A time-triggered `at` block with a time spec, optional guard, and body.

# `t`

```elixir
@type t() :: %Anemos.AST.At{
  body: list(),
  guard: term(),
  line: non_neg_integer() | nil,
  time_spec: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

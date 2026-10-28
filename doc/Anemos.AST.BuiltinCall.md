# `Anemos.AST.BuiltinCall`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L364)

A built-in function call (filter, map, reduce, emit).

# `t`

```elixir
@type t() :: %Anemos.AST.BuiltinCall{
  args: list(),
  line: non_neg_integer() | nil,
  name: :filter | :map | :reduce | :emit
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

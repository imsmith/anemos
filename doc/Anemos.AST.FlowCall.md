# `Anemos.AST.FlowCall`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L77)

A `flow <name>` statement: runs the stored flow of that name. Takes no inputs.

# `t`

```elixir
@type t() :: %Anemos.AST.FlowCall{
  line: non_neg_integer() | nil,
  name: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

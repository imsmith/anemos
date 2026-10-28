# `Anemos.AST.NextRule`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L317)

A `nextrule` statement: dispatches to a different rule's pipeline,
optionally carrying a `with { }` argument block.

# `t`

```elixir
@type t() :: %Anemos.AST.NextRule{
  args: Anemos.AST.BlockArgs.t() | nil,
  line: non_neg_integer() | nil,
  target: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

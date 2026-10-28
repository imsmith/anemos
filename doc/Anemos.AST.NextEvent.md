# `Anemos.AST.NextEvent`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L294)

A `nextevent` statement: transitions to another `when` block within the
same rule, optionally carrying a `with { }` argument block (A-55).

# `t`

```elixir
@type t() :: %Anemos.AST.NextEvent{
  args: Anemos.AST.BlockArgs.t() | nil,
  line: non_neg_integer() | nil,
  target: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.Condition`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L42)

A named condition declaration with a body and source line.

# `t`

```elixir
@type t() :: %Anemos.AST.Condition{
  body: list(),
  line: non_neg_integer() | nil,
  name: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.Flow`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L61)

A named flow declaration with a body and source line.

# `t`

```elixir
@type t() :: %Anemos.AST.Flow{
  body: list(),
  line: non_neg_integer() | nil,
  name: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

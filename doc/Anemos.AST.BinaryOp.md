# `Anemos.AST.BinaryOp`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L267)

A binary operator expression.

# `t`

```elixir
@type t() :: %Anemos.AST.BinaryOp{
  left: term(),
  line: non_neg_integer() | nil,
  op: atom() | nil,
  right: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.UnaryOp`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L218)

A unary operator expression.

# `t`

```elixir
@type t() :: %Anemos.AST.UnaryOp{
  line: non_neg_integer() | nil,
  op: atom() | nil,
  operand: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

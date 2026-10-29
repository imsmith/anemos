# `Anemos.AST.VarRef`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L293)

A variable reference with an optional sigil prefix.

# `t`

```elixir
@type t() :: %Anemos.AST.VarRef{
  line: non_neg_integer() | nil,
  name: String.t() | nil,
  sigil: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

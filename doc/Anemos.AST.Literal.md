# `Anemos.AST.Literal`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L216)

A literal value node (string, integer, float, boolean, atom).

# `t`

```elixir
@type t() :: %Anemos.AST.Literal{
  line: non_neg_integer() | nil,
  type: atom() | nil,
  value: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.QueryDecl`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L375)

A named query declaration with expect/engine/body/return, scope, and source line.

# `t`

```elixir
@type t() :: %Anemos.AST.QueryDecl{
  body: String.t() | nil,
  engine: String.t() | nil,
  expect: [String.t()],
  line: non_neg_integer() | nil,
  name: String.t() | nil,
  return: String.t() | nil,
  scope: :local | :global
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

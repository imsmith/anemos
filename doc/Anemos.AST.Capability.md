# `Anemos.AST.Capability`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L49)

A named capability declaration with context, body, and source line.

# `t`

```elixir
@type t() :: %Anemos.AST.Capability{
  body: list(),
  context: String.t() | nil,
  line: non_neg_integer() | nil,
  name: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

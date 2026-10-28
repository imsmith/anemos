# `Anemos.AST.Rule`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L30)

A named rule declaration with a body, optional metadata, and source line.

# `t`

```elixir
@type t() :: %Anemos.AST.Rule{
  body: list(),
  line: non_neg_integer() | nil,
  meta: map() | nil,
  name: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

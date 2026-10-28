# `Anemos.AST.Context`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L145)

A context scope block with a dotted path and body.

# `t`

```elixir
@type t() :: %Anemos.AST.Context{
  body: list(),
  line: non_neg_integer() | nil,
  path: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

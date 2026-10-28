# `Anemos.AST.If`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L97)

A conditional `if` block with an optional guard, body, and else branch.

# `t`

```elixir
@type t() :: %Anemos.AST.If{
  body: list(),
  condition: term(),
  else_body: list() | nil,
  guard: term(),
  line: non_neg_integer() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

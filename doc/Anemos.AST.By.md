# `Anemos.AST.By`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L160)

A `by <identity> that { ... }` attribution block inside an `it`. Its
body runs on entering the enclosing mode, attributed to `identity`.

# `t`

```elixir
@type t() :: %Anemos.AST.By{
  body: list(),
  identity: String.t() | nil,
  line: non_neg_integer() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

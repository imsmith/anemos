# `Anemos.AST.On`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L106)

An `on` invocation block triggered by a named invocation.

# `t`

```elixir
@type t() :: %Anemos.AST.On{
  body: list(),
  invocation: term(),
  line: non_neg_integer() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

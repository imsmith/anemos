# `Anemos.AST.Emit`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L223)

An `emit` expression that produces a typed value to an optional destination.

# `t`

```elixir
@type t() :: %Anemos.AST.Emit{
  destination: term(),
  label: term(),
  line: non_neg_integer() | nil,
  type: atom() | nil,
  value: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

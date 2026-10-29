# `Anemos.AST.It`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L138)

An `it <mode> [= <literal>]` block. `modal_ref` is `{mode, value}`,
`value` nil for a mode that only has to be active. The body holds
trigger blocks and `by` blocks, live only while the mode holds.

# `t`

```elixir
@type t() :: %Anemos.AST.It{
  body: list(),
  line: non_neg_integer() | nil,
  modal_ref: {String.t(), term()} | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.On`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L122)

An `on <interaction>` block. An interaction is an occurrence, not a
report: it has no truth, is never remembered, and admits `unless` but
not `for`, `until` or a compound form. See `Anemos.Runtime.Interaction`.

# `t`

```elixir
@type t() :: %Anemos.AST.On{
  body: list(),
  guard: term(),
  invocation: Anemos.Runtime.Interaction.t() | nil,
  line: non_neg_integer() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

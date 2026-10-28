# `Anemos.AST.Flow`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L61)

A `flow <name> { ... }` declaration: a stored, ordered workflow of
`nextrule` steps taken as a whole. The body holds `NextRule` nodes and
nothing else; a flow that should start on an event is a rule with
`when X { flow name }`.

# `t`

```elixir
@type t() :: %Anemos.AST.Flow{
  body: [Anemos.AST.NextRule.t()],
  line: non_neg_integer() | nil,
  name: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

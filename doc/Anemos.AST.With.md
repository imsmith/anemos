# `Anemos.AST.With`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L174)

A `with` fan-out. `with each var in iterable { }` runs the body once per
element; `with { }` (no `var`) runs each statement. Branches run
concurrently and their operations are kept in source order.

# `t`

```elixir
@type t() :: %Anemos.AST.With{
  body: list(),
  iterable: term(),
  line: non_neg_integer() | nil,
  var: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

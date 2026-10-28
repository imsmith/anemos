# `Anemos.AST.When`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L84)

A `when` trigger block: fires on an event, with optional duration, guard, and body.

# `t`

```elixir
@type t() :: %Anemos.AST.When{
  body: list(),
  duration: term(),
  event: String.t() | nil,
  guard: term(),
  line: non_neg_integer() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.Command`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L166)

A module command expression with a verb and arguments.

# `t`

```elixir
@type t() :: %Anemos.AST.Command{
  args: list(),
  line: non_neg_integer() | nil,
  module: String.t() | nil,
  verb: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

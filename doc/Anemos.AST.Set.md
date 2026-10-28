# `Anemos.AST.Set`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L159)

A `set` variable assignment.

# `t`

```elixir
@type t() :: %Anemos.AST.Set{
  line: non_neg_integer() | nil,
  name: String.t() | nil,
  value: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

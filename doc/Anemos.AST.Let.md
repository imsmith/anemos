# `Anemos.AST.Let`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L152)

A `let` variable binding.

# `t`

```elixir
@type t() :: %Anemos.AST.Let{
  line: non_neg_integer() | nil,
  name: String.t() | nil,
  value: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

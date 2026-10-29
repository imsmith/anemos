# `Anemos.AST.While`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L330)

A `while` loop: repeats body while condition is truthy.

# `t`

```elixir
@type t() :: %Anemos.AST.While{
  body: list(),
  condition: term(),
  line: non_neg_integer() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.As`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L153)

An `as "<mode>"` block: its body runs on entering the mode.

# `t`

```elixir
@type t() :: %Anemos.AST.As{
  body: list(),
  line: non_neg_integer() | nil,
  mode: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

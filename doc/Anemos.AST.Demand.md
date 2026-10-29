# `Anemos.AST.Demand`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L236)

A `demand` expression referencing a capability with a PAM-style control flag.

# `t`

```elixir
@type t() :: %Anemos.AST.Demand{
  capability: String.t() | nil,
  flag: atom() | nil,
  line: non_neg_integer() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

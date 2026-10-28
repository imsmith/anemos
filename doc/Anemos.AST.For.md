# `Anemos.AST.For`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L292)

A `for` loop: iterates `var` over `iterable`, executing body each time. Covers `for`, `each`, `every`, `foreach`.

# `t`

```elixir
@type t() :: %Anemos.AST.For{
  body: list(),
  iterable: term(),
  keyword: atom() | nil,
  line: non_neg_integer() | nil,
  var: String.t() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.AST.Triple`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L259)

An RDF-style triple with subject, predicate, and object.

# `t`

```elixir
@type t() :: %Anemos.AST.Triple{
  line: non_neg_integer() | nil,
  object: term(),
  predicate: term(),
  subject: term()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

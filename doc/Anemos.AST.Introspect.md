# `Anemos.AST.Introspect`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/ast.ex#L193)

An introspection statement — `show`, `list`, `graph`, `trace`,
`explain`, `exists`, `infer`, `assert` — or `exists` in expression
position. The subject is a bare `{:name, "NAME"}`, a `{:catalogue,
:rules | :conditions | :modules | :events | :policies | :schedules}`, or
`{:expr, expression}`.

# `t`

```elixir
@type t() :: %Anemos.AST.Introspect{
  line: non_neg_integer() | nil,
  subject: term(),
  verb: atom()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

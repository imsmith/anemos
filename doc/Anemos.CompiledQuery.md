# `Anemos.CompiledQuery`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiler.ex#L48)

A compiled query block.

# `t`

```elixir
@type t() :: %Anemos.CompiledQuery{
  body: String.t() | nil,
  engine: String.t() | nil,
  expect: [String.t()] | nil,
  handler: fun() | nil,
  name: String.t(),
  return: String.t() | nil,
  scope: :local | :global | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.CompiledData`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiler.ex#L31)

A compiled data block.

# `t`

```elixir
@type t() :: %Anemos.CompiledData{
  dataset: MapSet.t() | nil,
  dynamic: tuple() | nil,
  format: String.t() | nil,
  name: String.t(),
  raw: String.t() | nil,
  scope: :local | :global | nil,
  source: String.t() | nil,
  transclude: tuple() | nil
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.CompiledCapability`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiled_capability.ex#L1)

A compiled capability: name, context scope, and handler closure for on-demand execution.

# `t`

```elixir
@type t() :: %Anemos.CompiledCapability{
  context: String.t(),
  handler: (map() -&gt; {:ok, list()} | {:error, term()}),
  name: String.t()
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

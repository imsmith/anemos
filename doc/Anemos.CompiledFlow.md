# `Anemos.CompiledFlow`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiled_flow.ex#L1)

A compiled flow: its name and ordered steps. Each step names a rule and
carries a closure that resolves its `with { }` block against the invoking
dispatch's context, since a flow has no bindings of its own.

# `step`

```elixir
@type step() :: %{target: String.t(), args: (map() -&gt; map() | nil)}
```

# `t`

```elixir
@type t() :: %Anemos.CompiledFlow{name: String.t(), steps: [step()]}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

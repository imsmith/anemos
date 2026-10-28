# `Anemos.CompilationResult`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiler.ex#L70)

Result of compiling an Anemos program.

All fields default to empty lists — no fields are required at construction.

# `t`

```elixir
@type t() :: %Anemos.CompilationResult{
  capabilities: [Anemos.CompiledCapability.t()],
  conditions: [Anemos.CompiledCondition.t()],
  data_blocks: [Anemos.CompiledData.t()],
  query_blocks: [Anemos.CompiledQuery.t()],
  rules: [Anemos.CompiledRule.t()],
  schedules: [Anemos.CompiledSchedule.t()]
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

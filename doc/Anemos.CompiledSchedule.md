# `Anemos.CompiledSchedule`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiled_schedule.ex#L1)

A compiled schedule: event name, time spec, recurrence, and handler.

Produced by the compiler from `at` blocks. The scheduler uses these
to set timers and dispatch synthetic `AT_*` events.

# `t`

```elixir
@type t() :: %Anemos.CompiledSchedule{
  context: String.t() | nil,
  event_name: String.t(),
  handler: (-&gt; {:ok, [map()]}) | nil,
  recurrence: atom() | nil,
  time_spec:
    {:time, {non_neg_integer(), non_neg_integer()}}
    | {:date, {non_neg_integer(), non_neg_integer(), non_neg_integer()}}
    | {:day, atom()}
    | {:interval, {non_neg_integer(), atom()}}
    | {:delay_ms, non_neg_integer()}
}
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*

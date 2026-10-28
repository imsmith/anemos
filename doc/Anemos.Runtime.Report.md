# `Anemos.Runtime.Report`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/report.ex#L1)

What an event *reports*, and what a compound trigger makes of the reports
it has heard (A-47).

An event arriving is a report: true or false at the moment it is made. It
is true unless its payload carries a falsy `state` — the convention the
dwell timer already reads. That report stands as the event's state until
the next report of the same event; there is no other way for it to change,
and an event that has never reported is false.

`when (A AND B)` names a compound state over those reports. It is true if
and only if every operand is true as last reported, and it is evaluated at
each report of any operand. `OR` is true if any operand is.

The listener keeps the reports, not the event: a rule hears only what its
context admits, so two rules may hold different reports of the same event.

# `reports`

```elixir
@type reports() :: %{optional(String.t()) =&gt; boolean()}
```

# `truthy?`

```elixir
@spec truthy?(map()) :: boolean()
```

Whether the event arriving with `context` reports true.

## Examples

    iex> Anemos.Runtime.Report.truthy?(%{})
    true

    iex> Anemos.Runtime.Report.truthy?(%{context_data: %{"state" => false}})
    false

# `value`

```elixir
@spec value(:and | :or, [String.t()], reports()) :: boolean()
```

The compound state of `events` under `op`, given the last `reports`.

## Examples

    iex> Anemos.Runtime.Report.value(:and, ["A", "B"], %{"A" => true})
    false

    iex> Anemos.Runtime.Report.value(:and, ["A", "B"], %{"A" => true, "B" => true})
    true

    iex> Anemos.Runtime.Report.value(:or, ["A", "B"], %{"A" => false, "B" => true})
    true

---

*Consult [api-reference.md](api-reference.md) for complete listing*

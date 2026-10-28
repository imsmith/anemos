# `Anemos.Runtime.Introspection`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/introspection.ex#L1)

Answers the introspection statements — `show`, `list`, `graph`, `trace`,
`explain`, `exists`, `infer` — from the dispatcher's state.

The subject decides what is asked: a bare name is a module if one is
bound to it, else an event if anything listens for it; a catalogue word
names what the runtime holds; anything else is a value. The statement
decides the question, after Comn: `show` is look, `explain` is recon,
`list` is choices. See `docs/superpowers/specs/2026-10-03-introspection-design.md`.

Every answer is the operation with `value` filled in, and for a name,
`found`: `:module`, `:event` or `nil`.

## A policy sees itself, and the modules

Rules, conditions, schedules, policies and listeners are answered
within the asking rule's own policy: what it declared, and who among
its own rules listens. Another policy's names, contexts and condition
states are that policy's; the runtime-wide view belongs to the host
(`Anemos.Runtime.describe/1`). Modules are the affordances every policy
may ask about. A rule loaded with no policy name sees the other
anonymous loads, which share its standing.

# `answer`

```elixir
@spec answer(map(), map(), map()) :: map()
```

The operation, answered for the rule named in `context[:_rule_source]`.

# `statements`

```elixir
@spec statements() :: [atom()]
```

The statement types this answers.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

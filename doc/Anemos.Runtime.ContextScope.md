# `Anemos.Runtime.ContextScope`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/context_scope.ex#L1)

The one comparison that decides whether one context path lies inside another.

Under the 2026-08-06 multi-tenant decision `context` is a security
boundary, so this predicate is the boundary check itself, and two
properties matter more than convenience:

**It compares path segments, not string prefixes.** `garage` and
`garageband.amp` share a prefix and share no context; treating
`String.starts_with?/2` as containment let the second reach rules scoped
to the first (A-06).

**It fails closed.** An absent inner path is not "unscoped and therefore
allowed" — it is a caller that did not say where it was standing, and a
declared boundary has to refuse it. The one direction that opens is an
absent *outer* path, which means no boundary was declared at all.

Both the dispatcher's rule filter (A-06, A-39) and the capability
server's demand gate (A-07) call this, deliberately: two copies of a
boundary check are two chances to fix only one of them.

# `within?`

```elixir
@spec within?(String.t() | nil, String.t() | nil) :: boolean()
```

True when `inner` names the same context as `outer` or a context beneath it.

`outer` is the declared boundary — a rule's `context` block, or a
capability's `context` line. `inner` is whoever is trying to cross it —
the event's `:context_path`, or the demanding rule's context.

## Examples

    iex> alias Anemos.Runtime.ContextScope
    iex> ContextScope.within?("garage", "garage")
    true
    iex> ContextScope.within?("garage.door", "garage")
    true
    iex> ContextScope.within?("garageband.amp", "garage")
    false
    iex> ContextScope.within?(nil, "garage")
    false
    iex> ContextScope.within?(nil, nil)
    true

---

*Consult [api-reference.md](api-reference.md) for complete listing*

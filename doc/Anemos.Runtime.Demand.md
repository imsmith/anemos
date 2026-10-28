# `Anemos.Runtime.Demand`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/demand.ex#L1)

Evaluates a stack of demand operations against capability servers
using PAM-style control flag semantics.

Flags:
- `:requisite` (default) — must succeed, fail immediately if not
- `:required` — must succeed, but evaluate rest of stack before failing
- `:optional` — continue whether it succeeds or fails
- `:sufficient` — if succeeds, skip rest of stack

## Missing capabilities are not failures

The flags above govern how *failure* is handled. A capability that is not
present in the registry has not failed — it was never loaded, which is a
configuration error in the policy text (typically a typo in the capability
name). Such a demand is fatal under every flag, including `:optional` and
`:sufficient`.

Were it otherwise, a stack composed entirely of `:optional` demands naming
capabilities that do not exist would return `{:ok, []}` — a gate that reads
as an authorization check while authorizing nothing.

## Neither is a context denial

For the same reason, a capability refused because the demanding rule sits
outside its declared context is fatal under every flag. Failure flags
describe how much a policy may tolerate a capability that *tried and could
not*; they do not get to describe how much it may tolerate crossing a
security boundary. The demanding rule's context is read from the
`:_rule_source` the dispatcher stamps into the execution context, and an
absent one denies — see `Anemos.Runtime.ContextScope`.

# `evaluate`

```elixir
@spec evaluate([map()], map(), map()) :: {:ok, list()} | {:error, term()}
```

Evaluates a demand stack against capability servers using PAM-style control flags.

Each demand in the list must have `:capability` (name) and `:flag` (one of
`:requisite`, `:required`, `:optional`, `:sufficient`).

Returns `{:ok, operations}` or `{:error, reason}`.

## Examples

    iex> {:ok, pid} = Anemos.Runtime.CapabilityServer.start_link(name_str: "k", context: nil, handler: fn _ -> {:ok, [%{type: :log, value: "ok"}]} end)
    iex> {:ok, ops} = Anemos.Runtime.Demand.evaluate([%{capability: "k", flag: :requisite}], %{"k" => pid}, %{})
    iex> [%{type: :log, value: "ok"}] = ops
    [%{type: :log, value: "ok"}]

---

*Consult [api-reference.md](api-reference.md) for complete listing*

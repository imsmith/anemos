# `Anemos.Runtime.Interaction`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/interaction.ex#L1)

The vocabulary shared by `on <interaction>` blocks and the host.

A `when` takes a *report*: an event with a truth at the time it arrives,
which stands until the next report of the same event and feeds compound
triggers, dwell timers and conditions. An `on` takes an *interaction*: an
occurrence with no truth, never remembered, fired once per occurrence.
Boot, shutdown, a keypress, a login — things that happen, not claims
about the world.

Interactions travel the same index as events under names in the reserved
`ON_` namespace, which `when` may not subscribe to and `dispatch/4` may
not send. The compiler and the runtime both derive those names here so a
host's `interact(:rt, {:keypress, "ESC"})` meets the block compiled from
`on keypress "ESC"`.

# `t`

```elixir
@type t() :: :boot | :shutdown | {:keypress, String.t()} | {:named, String.t()}
```

# `event_name`

```elixir
@spec event_name(t()) :: String.t()
```

The event name an interaction is indexed under.

# `from_host`

```elixir
@spec from_host(term()) :: {:ok, t()} | {:error, Comn.Errors.ErrorStruct.t()}
```

What a host may raise: a keypress, or a named interaction written like an
event id. Boot and shutdown are the runtime's to raise, at the points a
policy becomes active and stops being so.

# `reserved?`

```elixir
@spec reserved?(String.t()) :: boolean()
```

Whether an event name sits in the interaction namespace.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

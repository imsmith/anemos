# `Anemos`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos.ex#L1)

Anemos — event-driven automation DSL.

Provides `run/2` to parse, compile, and dispatch a rule source string
against a given event in a single call.

# `report`

```elixir
@type report() :: %{
  event: String.t(),
  context_path: String.t() | nil,
  operations: list(),
  results: list(),
  errors: list(),
  subscribed: non_neg_integer(),
  reachable: non_neg_integer()
}
```

What a single `run/2` actually did, beyond the operations it produced.

`:subscribed` and `:reachable` exist because an empty result list has
three unrelated causes, and a caller that cannot tell them apart cannot
act on any of them: nothing subscribed to the event, something subscribed
but the context boundary denied it, or a rule ran and every branch was
false. See `run_report/2`.

# `default_modules`

```elixir
@spec default_modules() :: %{required(String.t()) =&gt; module()}
```

The default module registrations used by `run/2` and `run_report/2`.

Every one of these is a development stub: it computes in memory and
performs no I/O. They exist so the DSL and the shipped examples can be
exercised, not so a rule file can manage real infrastructure.

# `example_modules`

```elixir
@spec example_modules() :: %{required(String.t()) =&gt; module()}
```

Fake module registrations that let `priv/examples/` run end to end.

These are demonstration doubles, not implementations: they compute from
their arguments and the supplied context data and touch nothing outside
the VM. Pass them explicitly (`modules: Anemos.example_modules()`, or
`mix anemos.run --stub-modules`) — they are not registered by default,
because `SECRET` and `INFRA` answering plausibly is exactly the failure a
policy author needs to see rather than sail past.

# `run`

```elixir
@spec run(String.t(), keyword()) ::
  {:ok, list()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Parse, compile, and dispatch an event against rules in `source`.

Options:
  - `:event` — the event name to dispatch (required)
  - `:context` — optional raw runtime context map (default `%{}`)
  - `:context_path` — the context the caller occupies, for boundary
    matching against each rule's `context` block
  - `:context_data` — external key-value data that `?var` resolves against
  - `:modules` — extra module registrations, merged over `default_modules/0`
  - `:authorization` — passed through to the configured
    `Anemos.Runtime.LoadAuthority` as `LoadRequest.authorization`; a token,
    a peer identity, whatever the authority was written to check

`:context_path` and `:context_data` are merged into `:context`; they are a
convenience for callers that would otherwise hand-build the map. They are
two different things: the first is the scope the caller is standing in,
the second is the data it brought with it.

## The load is gated

`source` goes through the same trust boundary as
`Anemos.Runtime.load/3`: the unwaivable `:max_policy_bytes` ceiling, then
the module configured as `config :anemos, :load_authority` (A-59). This
is not a developer shortcut around the boundary — a host embedding this
to execute policy it did not write gets the gate it configured, here as
well as there.

A refusal is `{:error, %Comn.Errors.ErrorStruct{}}` with code
`anemos.runtime/load_denied`. The default authority is
`LoadAuthority.Permissive`, so an embedder that has configured nothing
sees no change.

Returns `{:ok, results}` or `{:error, reason}`. Use `run_report/2` when an
empty result list needs to be distinguished from a boundary denial.

## Examples

    iex> source = "rule t { when EV { [DEVICE::set \"light\" \"on\"] } }"
    iex> {:ok, [%{module: "DEVICE", verb: "set", args: ["light", "on"]}]} =
    ...>   Anemos.run(source, event: "EV")

    iex> source = "rule t { context \"garage\" { when EV { log \"hi\" } } }"
    iex> {:ok, []} = Anemos.run(source, event: "EV")
    iex> {:ok, [_]} = Anemos.run(source, event: "EV", context_path: "garage")

    iex> {:error, _} = Anemos.run("rule {", event: "EV")

# `run_report`

```elixir
@spec run_report(String.t(), keyword()) ::
  {:ok, report()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Like `run/2`, but returns a `t:report/0` instead of a bare result list.

## Examples

    iex> source = "rule t { context \"garage\" { when EV { log \"hi\" } } }"
    iex> {:ok, denied} = Anemos.run_report(source, event: "EV")
    iex> {denied.subscribed, denied.reachable, denied.operations}
    {1, 0, []}

    iex> source = "rule t { when EV { log \"hi\" } }"
    iex> {:ok, silent} = Anemos.run_report(source, event: "OTHER")
    iex> {silent.subscribed, silent.reachable}
    {0, 0}

---

*Consult [api-reference.md](api-reference.md) for complete listing*

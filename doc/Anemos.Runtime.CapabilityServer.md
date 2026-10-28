# `Anemos.Runtime.CapabilityServer`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/capability_server.ex#L1)

GenServer for a single named capability.
Passive until demanded. Executes its `on demand` handler and returns the result.

## The context check lives here

A capability's `context` line names who may demand it. The check is made
in this process rather than in `Anemos.Runtime.Demand` because this is
where the capability's own declared context lives: a caller cannot reach
the handler without passing an argument that says where it is standing,
and an argument it forgets to pass is a denial rather than a pass (A-07).

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `execute`

```elixir
@spec execute(pid() | atom(), map(), String.t() | nil) ::
  {:ok, list()} | {:error, term()}
```

Executes the capability's on-demand handler with the given context.

`demanding_context` is the context path of the rule making the demand.
It must lie within the capability's declared context — see
`Anemos.Runtime.ContextScope`. A capability declared without a context is
demandable from anywhere; a capability *with* one refuses a demander that
names no context at all.

Returns `{:ok, operations}`, `{:error, {:context_denied, error}}`, or
`{:error, reason}` from the handler.

## Examples

    iex> {:ok, pid} = Anemos.Runtime.CapabilityServer.start_link(name_str: "k", context: nil, handler: fn _ -> {:ok, []} end)
    iex> Anemos.Runtime.CapabilityServer.execute(pid, %{})
    {:ok, []}

    iex> {:ok, pid} = Anemos.Runtime.CapabilityServer.start_link(name_str: "k", context: "infra.networking", handler: fn _ -> {:ok, [:secret]} end)
    iex> Anemos.Runtime.CapabilityServer.execute(pid, %{}, "infra.networking.dns")
    {:ok, [:secret]}
    iex> {:error, {:context_denied, _}} = Anemos.Runtime.CapabilityServer.execute(pid, %{}, nil)

# `start_link`

Starts a capability server.

## Options

  * `:name_str` — the capability name (required)
  * `:context` — the context scope, or `nil` for an unscoped capability (required)
  * `:handler` — 1-arity function `(context) -> {:ok, ops} | {:error, reason}` (required)
  * `:name` — process registration name (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*

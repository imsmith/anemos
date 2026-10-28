# `Anemos.Runtime.Standalone`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/standalone.ex#L1)

Wires a dispatcher and its stores together outside a full `Anemos.Runtime`
tree.

`Anemos.Runtime.Dispatcher` deliberately starts nothing: its stores belong
to `Anemos.Runtime.StoreSupervisor` and its policy set to
`Anemos.Runtime.PolicyStore`. That is the right shape for a supervised
runtime, but it makes the one-shot case — `Anemos.run/2`, and tests that
want a dispatcher and nothing else — a three-step dance. This module is
that dance, in one call.

Everything it starts is linked to the caller, so a test process exiting
takes the whole set with it. `stop/1` tears the set down explicitly for
callers that outlive it — without which `Anemos.run/2` leaked its stores
on every invocation, since `GenServer.stop/1` exits `:normal` and
non-trapping linked processes ignore that signal.

# `start_link`

```elixir
@spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
```

Starts a policy store, a store supervisor and a dispatcher, and returns
the dispatcher.

## Options

  * `:registry` — pid or name of a `ModuleRegistry` (required)
  * `:rules`, `:conditions`, `:capabilities`, `:data_blocks` — seeded into
    the policy store before the dispatcher starts, so a dispatcher restart
    rebuilds them (all optional)
  * `:channel_connector` — recorded in the policy store (optional)
  * `:subscribable_registry` — an existing registry whose contents are
    copied into the supervised one (optional)
  * `:name` — dispatcher registration name (optional)

# `stop`

```elixir
@spec stop(pid() | atom()) :: :ok
```

Stops a dispatcher started by `start_link/1` and everything under it.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

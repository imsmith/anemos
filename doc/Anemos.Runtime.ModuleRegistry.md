# `Anemos.Runtime.ModuleRegistry`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/module_registry.ex#L1)

Maps module names (e.g. "DEVICE", "FILE") to Elixir modules
implementing the `Anemos.Runtime.Module` behaviour.

## Trust model

This table decides where every `[MODULE::verb ...]` in every loaded policy
executes. It is reachable by a documented public name
(`:"#{runtime_name}.registry"`), so any process in the VM can address it.
Registration is therefore **write-once**: binding a name that is already
live is refused and logged, so a later `register/3` cannot silently
redirect `"SECRET"` or `"INFRA"` at a module of someone else's choosing
while the policy continues to look normal from outside.

Three outcomes:

  * name unbound — bound, logged at `:info`
  * name bound to the *same* module — idempotent `:ok` (host code and
    tests re-register defaults freely)
  * name bound to a *different* module — an
    `anemos.runtime/already_registered` error, logged at `:warning`,
    binding unchanged

A deliberate rebind is still possible, but it has to say so:
`register(reg, name, module, replace: true)`. That path also logs at
`:warning`, because a verb changing destination mid-flight is an event an
operator should see either way.

This raises the bar from "any process can rebind" to "any process can
rebind loudly, and only by asking". It is not an authorization check —
there is no caller identity to check against. A registry that must not be
written by arbitrary code should not be given a public name.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `lookup`

```elixir
@spec lookup(pid() | atom(), String.t()) :: {:ok, module()} | :error
```

Looks up a module by name.

Returns `{:ok, module}` or `:error`.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
    iex> Anemos.Runtime.ModuleRegistry.lookup(reg, "MISSING")
    :error

# `names`

```elixir
@spec names(pid() | atom()) :: [String.t()]
```

Lists every bound module name, sorted. For auditing what a runtime can reach.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
    iex> Anemos.Runtime.ModuleRegistry.names(reg)
    []

# `register`

```elixir
@spec register(pid() | atom(), String.t(), module(), keyword()) ::
  :ok | {:error, Comn.Errors.ErrorStruct.t()}
```

Registers an Elixir module under the given name (e.g., `"DEVICE"`).

Write-once. Re-registering the same module is idempotent; binding a live
name to a different module is refused unless `replace: true` is given.
Every outcome is logged. See the module docs for the trust model.

## Options

  * `:replace` — when `true`, deliberately rebind a live name (default `false`)

## Examples

    iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
    iex> Anemos.Runtime.ModuleRegistry.register(reg, "DEVICE", Anemos.Runtime.Modules.Device)
    :ok
    iex> {:error, error} =
    ...>   Anemos.Runtime.ModuleRegistry.register(reg, "DEVICE", Anemos.Runtime.Modules.File)
    iex> error.code
    "anemos.runtime/already_registered"

# `registered?`

```elixir
@spec registered?(pid() | atom(), String.t()) :: boolean()
```

Returns true if `name` is currently bound.

## Examples

    iex> {:ok, reg} = Anemos.Runtime.ModuleRegistry.start_link([])
    iex> Anemos.Runtime.ModuleRegistry.registered?(reg, "DEVICE")
    false

# `start_link`

Starts a module registry.

## Options

  * `:name` — process registration name (optional)
  * `:state_table` — an `Anemos.Runtime.StateTable` the bindings are kept
    in, so that this process restarting does not lose them (A-43).
    Optional; without it a restarted registry is empty.
  * `:modules` — `%{name => module}` bound at start, under whatever the
    table remembers (optional)

---

*Consult [api-reference.md](api-reference.md) for complete listing*

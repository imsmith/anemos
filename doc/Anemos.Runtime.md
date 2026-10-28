# `Anemos.Runtime`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime.ex#L1)

Supervisable runtime interpreter for Anemos policies.

Start a blank interpreter in your supervision tree, then load modules
and policies into it dynamically.

## Usage

    # Start the interpreter
    children = [
      {Anemos.Runtime, name: :anemos}
    ]
    Supervisor.start_link(children, strategy: :one_for_one)

    # Register modules
    Anemos.Runtime.register(:anemos, "DEVICE", MyApp.Device)
    Anemos.Runtime.register(:anemos, "INFRA", MyApp.Infra)

    # Load policies
    Anemos.Runtime.load(:anemos, File.read!("policies/ddns.rule"))
    Anemos.Runtime.load(:anemos, File.read!("policies/garage.rule"))

    # Dispatch events
    Anemos.Runtime.dispatch(:anemos, "SENSOR_MOTION_DETECTED")

## Options

  * `:name` — required, used to register and address the runtime
  * `:keyring` — `%{signer_name => Comn.Secrets.Key.t()}` of **public**
    keys, used by `Anemos.Runtime.LoadAuthority.Signed` to verify the
    detached signature of a policy that declares `signed_by` (A-05).
    Defaults to empty, which means every declared signer is unknown and
    therefore refused. See `Anemos.Runtime.TrustStore`.
  * `:unsigned_policy` — `:strict | :warn | :permit` for sources that
    declare no signer at all. Defaults to `:permit`; see
    `Anemos.Runtime.TrustStore` for why the default is the insecure one
    and when that must be revisited.
  * `:watch` — a directory of `*.rule` files to keep deployed: saving a
    file deploys it, deleting it unloads it. See `Anemos.Runtime.Watcher`.
  * `:modules` — `%{"NAME" => module}` bound from the start, so that a
    policy deployed at boot already has them. `register/3` after start
    does the same thing later.

# `load_failure`

```elixir
@type load_failure() :: Comn.Errors.ErrorStruct.t()
```

One declaration that loaded but will never do anything.

A structured error. Its `code` says what kind of declaration and why —
`anemos.scheduler/<reason>` for a schedule, `anemos.data/<reason>` for a
data block — and its `field` names the declaration: the synthetic `AT_*`
event name for a schedule, the block name for a data block.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `condition_state`

```elixir
@spec condition_state(atom(), String.t()) :: boolean() | nil
```

Returns the current boolean state of a named condition, or `nil` if not found.

# `connect`

```elixir
@spec connect(atom(), module()) :: :ok
```

Connects a channel connector to the runtime.

The connector must implement the `Anemos.Channel` behaviour.
Replaces the current connector (default: `Anemos.Channel.Logger`).

# `describe`

```elixir
@spec describe(atom(), keyword()) :: map()
```

Everything the runtime holds, as it stands now.

`%{policies, rules, conditions, capabilities, data_blocks, schedules,
modules}`. Each rule carries the policy that declared it, the events it
listens for, its context, its `set` bindings and the state of its dwell
timers; each condition its current value.

Bindings are returned as they are. An `Anemos.Secret` stays wrapped.

Options: `:timeout` (default 5000 ms), for each of the calls this makes.

# `dispatch`

```elixir
@spec dispatch(atom(), String.t() | Anemos.Event.t(), map(), keyword()) ::
  {:ok, list()}
```

Dispatches an event into the running interpreter.

Accepts either a string event name (with optional context map) or any
value implementing the `Anemos.Event` protocol.

## Examples

    # String API
    Anemos.Runtime.dispatch(:anemos, "SENSOR_MOTION_DETECTED")
    Anemos.Runtime.dispatch(:anemos, "EVENT", %{context_path: "garage"})

    # Protocol API — any type that implements Anemos.Event
    Anemos.Runtime.dispatch(:anemos, my_mqtt_message)

    # Map shorthand
    Anemos.Runtime.dispatch(:anemos, %{name: "MOTION", context: "garage", payload: %{}})

Options: `:timeout`, how long to wait for the rules to run (default
5000 ms). A context map's `:correlation_id` is carried into the ambient
`Comn` context the rules run under, so what they emit shares it.

# `explain`

```elixir
@spec explain(atom(), String.t(), map(), keyword()) :: %{
  rules: [map()],
  conditions: [String.t()]
}
```

What dispatching `event_name` would do, without doing it.

`%{rules: [...], conditions: [...]}`. Each rule that listens for the event
is listed with the policy that declared it and an `outcome`: `:fires`,
`{:dwell, ms}` for a `when ... for` rule that would arm or hold its timer,
`:not_true` for a compound `when (A AND B)` whose state the report would
leave false,
or `:context_mismatch` when its `context` does not admit `context`'s
`:context_path`. `conditions` names the conditions that would evaluate.

Nothing is evaluated: a guard, an `if`, or a verb called in an expression
can still change what a rule that `:fires` goes on to do.

Options: `:timeout` (default 5000 ms).

# `load`

```elixir
@spec load(atom(), String.t(), keyword()) ::
  :ok | {:partial, [load_failure()]} | {:error, Comn.Errors.ErrorStruct.t()}
```

Loads a policy source string into the running interpreter. **Privileged.**

Parses and compiles the source, then adds the resulting rules,
conditions, and capabilities to the dispatcher and arms any schedules.
Can be called multiple times — policies accumulate.

## Deploying: `policy: id`

A load that names its policy replaces whatever was last loaded under that
name, exactly: afterwards the runtime holds what this source declares and
nothing the previous version declared that this one does not.

    Anemos.Runtime.load(:anemos, File.read!(path), policy: "garage/lights.rule")

A rule or condition whose text did not change keeps its state — `set`
bindings, armed dwell timers, the condition's boolean — however much of
the file around it was edited. One whose text changed starts from nothing.
A source that fails to load changes nothing; the deployed version keeps
running. Declaring a rule, condition or capability name that another
named policy holds is refused, and nothing is loaded.

Without `:policy` the load is anonymous: it can only add, and replace
rules by name — and not a name a named policy holds, which is refused the
same way. The name is passed to the load authority as
`Anemos.Runtime.LoadRequest`'s `policy`.

## This is the trust boundary

Whoever controls `source` controls every verb registered in this runtime.
The call is therefore gated (A-12): it is checked against a source-size
ceiling, then handed to the module configured as `config :anemos,
:load_authority` as an `Anemos.Runtime.LoadRequest`. It is also *not*
reachable through `act/1` — see `Anemos.Runtime.LoadAuthority` for why
each of those three is here and what each is worth.

Pass whatever your authority needs to identify the caller as
`:authorization`:

    Anemos.Runtime.load(:anemos, source, authorization: %{tenant: "acme", token: tok})

The default authority permits everything, so an embedder that has not
configured one sees the pre-A-12 behaviour unchanged.

## Return values

  * `:ok` — the whole policy loaded and every schedule armed.

  * `{:partial, failures}` — the policy loaded, but the listed
    declarations are inert and will never fire. `failures` is a list of
    `t:load_failure/0`. The rules, conditions and capabilities in the
    same source *did* load and will fire; this is not a rollback.

  * `{:error, reason}` — nothing loaded. The source failed to parse or
    compile, or the load was refused. A refusal is a
    `Comn.Errors.ErrorStruct` with code `anemos.runtime/load_denied`; a
    parse or compile failure is one with a code under `anemos.lexer/`,
    `anemos.parser/` or `anemos.compiler/`.

The distinction between the last two is the point. Arming a schedule and
starting a data block subscription are per-declaration best-effort — an
interval below the floor or a protocol with no registered handler stops
that one declaration, not the policy. Collapsing that into `{:error, _}`
would claim the rules had not loaded, when they had; collapsing it into
`:ok` (as this function used to) hides a policy that will never fire.

## Examples

    case Anemos.Runtime.load(:anemos, source) do
      :ok -> :ready
      {:partial, failures} -> Logger.warning("inert declarations: " <> inspect(failures))
      {:error, reason} -> {:error, reason}
    end

# `policies`

```elixir
@spec policies(atom()) :: [map()]
```

The loaded policies in load order, each as
`%{id, rules, conditions, capabilities, schedules, data_blocks}` with the
names it declares. A load that named no policy has `id: nil`.

# `put_context`

```elixir
@spec put_context(atom(), String.t(), term()) :: :ok
```

Stores context data for `?` variable resolution.

# `register`

```elixir
@spec register(atom(), module()) :: :ok
```

Registers a module with the runtime.

Accepts either a module built with `use Anemos.Module` (which carries
its own name), or a name string and module pair.

## Examples

    # Module with embedded name
    Anemos.Runtime.register(:anemos, MyApp.Anemos.Secret)

    # Explicit name
    Anemos.Runtime.register(:anemos, "DEVICE", MyApp.Device)

# `register`

```elixir
@spec register(atom(), String.t(), module()) :: :ok
```

# `register_data_model`

```elixir
@spec register_data_model(atom(), module()) :: :ok
```

Registers an `Anemos.DataModel` handler under the keyword it answers from
`keyword/0`. The keyword then names a format in a `data` block
(`data d { edn { ... } }`) and an engine in a `query` block.

Like a module, a handler is the host's to supply: the runtime ships none.
Register it before loading a policy that names it — a `data` block whose
format has no handler is a failure of that `load/3`.

# `start_link`

Starts the runtime supervisor.

# `trace`

```elixir
@spec trace(atom(), pos_integer()) :: [map()]
```

The most recent dispatches, newest first.

Each is `%{at, event, context_path, steps, conditions, results,
duration_us}`. `steps` is every rule the event reached, in order, with
what happened — `:fired`, `:dwell`, `:dwell_fired`, `:not_true` or
`:context_mismatch` — including rules reached through `nextevent`, `nextrule` and `emit ...
as`. `conditions` names the conditions that became true. `results` gives
the kind of each operation; a `log` carries its text, since that was
written to the log anyway, and nothing else carries a value.

The last 200 are kept, and they outlive a dispatcher crash — which is
when they are wanted.

# `unload`

```elixir
@spec unload(atom(), String.t()) :: :ok | {:error, Comn.Errors.ErrorStruct.t()}
```

Removes a policy that was loaded with `policy: policy_id`, and everything
it declared: rules and their state, conditions, capabilities, global data
blocks and their live feeds, and any schedule no other policy declares.

Not gated: whoever can call it can remove any policy by name. The gated
way is from inside a policy — `[POLICY::unload "id"]`, see
`Anemos.Runtime.Modules.Policy` — where the authority that admitted the
calling policy stands for the removal (A-81).

# `watcher_name`

```elixir
@spec watcher_name(atom()) :: atom()
```

The registered name of the directory watcher started by `watch:`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

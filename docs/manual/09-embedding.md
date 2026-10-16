# 9. Embedding and extending Anemos

Anemos is an interpreter library. The host application starts it, installs
modules and policies, and supplies events. This chapter builds that host one
piece at a time. You can run the examples in `iex -S mix` from this checkout.

## Start a persistent runtime

```elixir
{:ok, runtime_pid} = Anemos.Runtime.start_link(name: :anemos)
```

In an application, put the runtime in its supervision tree instead:

```elixir
children = [
  {Anemos.Runtime, name: :anemos}
]
Supervisor.start_link(children, strategy: :one_for_one)
```

Choose one of these approaches; do not start two runtimes with the same name.
Names are host-controlled atoms. Use a bounded set of configured names rather
than generating atoms from user input.

A persistent runtime starts with `POLICY` registered, but without the
development `DEVICE` and `FILE` defaults used by `Anemos.run/2`. Register
what your application needs. Supplying modules at startup is especially
useful with a watcher that loads policies immediately:

```elixir
{Anemos.Runtime, name: :anemos, modules: %{"DEVICE" => MyApp.Device}}
```

## Define a real command contract

This small host module performs a deterministic calculation, so you can test
the whole path without any external service:

```elixir
defmodule Tutorial.Math do
  use Anemos.Module, name: "MATH"

  @impl Anemos.Runtime.Module
  def arg_schema("double"), do: [[type: :number]]
  def arg_schema(_verb), do: nil

  verb :double, fn [number], _context -> {:ok, number * 2} end
end

:ok = Anemos.Runtime.register(:anemos, Tutorial.Math)
```

Every handler receives a list of resolved arguments and a context map, and
returns `{:ok, value}` or `{:error, reason}`. The macro supplies the module
name, unknown-verb fallback, and basic introspection. You can also implement
the `Anemos.Runtime.Module` behavior directly and register an explicit name:

```elixir
Anemos.Runtime.register(:anemos, "MATH", Tutorial.Math)
```

Now load a policy:

```anemos
rule calculate {
  when NUMBER {
    let doubled = [MATH::double ?number]
    log @doubled
  }
}
```

Put that source in a string called `source`, then:

```elixir
:ok = Anemos.Runtime.load(:anemos, source, policy: "math.rule")
{:ok, results} = Anemos.Runtime.dispatch(:anemos, "NUMBER",
  %{context_data: %{"number" => 21}})
# results includes %{type: :log, value: 42}
```

In value position, the command's unwrapped success value becomes `@doubled`.
In statement position, the command's success value is an operation result.
Host failures in value position stop the current handler's evaluation. Use
structured domain errors where possible; the runtime also normalizes ordinary
module failures into its error reporting system.

Registration is write-once by default. Registering the same name and module
again is idempotent; registering a different module under an occupied name
returns `anemos.runtime/already_registered`. A deliberate rebind uses the
lower-level registry API with `replace: true` and is logged:

```elixir
Anemos.Runtime.ModuleRegistry.register(
  :"anemos.registry", "MATH", MyApp.ReplacementMath, replace: true)
```

Treat changing a module's behavior as an API change for every policy using it.

## Validate inputs at the module boundary

The optional `arg_schema/1` callback declares positional arguments. The
dispatcher applies it to both standalone and value-position calls before host
code runs. A `nil` schema leaves the verb unvalidated.

| Spec key | Purpose |
| --- | --- |
| `type:` | `:string`, `:integer`, `:float`, `:number`, `:boolean`, `:atom`, `:any` |
| `max_bytes:` | Limit a string's byte length |
| `in:` | Restrict to an explicit list of values |
| `optional: true` | Allow a trailing argument to be absent |
| `rest: true` | Apply the final spec to remaining arguments |
| `path:` | Normalize and confine a path to a configured root |

Remember that policy symbols evaluate to strings, so `:atom` describes a
value supplied by host data, not the DSL's `:symbol` syntax. Schemas do not
coerce CLI strings into numeric or boolean values. Business decisions and
cross-argument constraints belong in the handler itself.

For a filesystem verb, configure a root and declare a path argument:

```elixir
# In config/config.exs:
config :anemos, :path_roots, %{documents: "/var/lib/my_app/documents"}

# In the host module:
def arg_schema("read") do
  [[type: :string, max_bytes: 4096, path: :documents]]
end
```

The validated argument becomes a confined absolute path. Pass that value
directly to the filesystem API instead of resolving the original input again.
The shipped `FILE` is a stub; its shape checks alone do not make a future
filesystem implementation confined. `Anemos.Runtime.PathGuard` performs
lexical normalization and containment. It does not resolve symlinks: an
in-root link pointing outside the root can escape it. Use filesystem-level
confinement when that boundary must withstand changes to the directory tree.

## Supply event data

The string API accepts a context map:

```elixir
Anemos.Runtime.dispatch(:anemos, "READING", %{
  context_path: "building.garage.sensor",
  context_data: %{"temperature" => 24, "enabled" => true},
  correlation_id: "reading-001"
})
```

Use string payload keys. Supply all fields needed for `?` lookup in this
dispatch's `context_data`. `Runtime.put_context/3` writes a separate context
store, but that store is not currently merged into ordinary dispatch lookup.
To supply shared defaults, merge them in the host before dispatch:

```elixir
defaults = %{"site" => "west"}
payload = Map.merge(defaults, %{"temperature" => 24})
Anemos.Runtime.dispatch(:anemos, "READING", %{context_data: payload})
```

For ordinary maps there is also a protocol shorthand:

```elixir
Anemos.Runtime.dispatch(:anemos, %{
  name: "READING",
  context: "building.garage.sensor",
  payload: %{"temperature" => 24}
})
```

The shorthand's outer keys are atoms and use `context`/`payload`; the string
API's context map uses `context_path`/`context_data`. Confusing these shapes
is a common cause of missing data or denied contexts.

Application event structs can implement `Anemos.Event` with `name/1`,
`context/1`, and `payload/1`. Return an exact event-name string, a path or
`nil`, and a payload map. The protocol form derives those fields from the
event; use the string form when you need the richer dispatch context.
`correlation_id` in the string context is carried into the ambient Comn
context used by operations.

## Emit values and connect a channel

`emit` currently takes a command expression. It evaluates that command,
then produces an emit operation containing its returned value:

```anemos
rule publish-reading {
  when READING {
    emit state [SENSOR::read] to channel(telemetry.readings) as :reading.ready
  }
}
```

The host supplies `SENSOR::read`. The optional type is `state`, `effect`, or
`stream`; it is an envelope tag, not an automatic storage, streaming, or
delivery guarantee. `emit ?payload` is not the implemented emit syntax.

With a channel destination, the runtime calls the current connector's
`publish/2` with an `Anemos.Envelope`. Its fields are:

| Field | Meaning |
| --- | --- |
| `type` | `:state`, `:effect`, `:stream`, or `nil` |
| `payload` | The command's returned value |
| `source` | Declaration name, optionally `name@context` |
| `timestamp` | UTC emission time |
| `label` | The `as` label, if any |
| `channel` | Destination path |
| `signature` | Reserved field; publishing does not sign automatically |

The default connector, `Anemos.Channel.Logger`, logs channel emits. To use
the bundled in-process event bus connector:

```elixir
:ok = Anemos.Runtime.connect(:anemos, Anemos.Channel.ComnBus)
Comn.EventBus.subscribe("telemetry.readings")
# The subscriber receives {:event, topic, %Anemos.Envelope{}}
```

Or implement `Anemos.Channel.publish(channel, envelope)` and connect your
module. A connector is host infrastructure, so design its retry, buffering,
serialization, and error reporting explicitly. The current emit path does
not turn a connector's returned `{:error, reason}` into a failed operation.

A binary `as` label also redispatches an event internally after the current
operation list. The redispatch retains the originating context/payload; it
does not automatically install the emitted command result as a new payload.
Use `nextevent ... with` to send explicit fields. Labels are strings after
parsing. Interpolated-label spellings are accepted but not dynamically
resolved; prefer fixed labels with understood subscriptions.

## Supply a complete data handler

This implementation makes the `words` examples in Chapter 8 concrete:

```elixir
defmodule Tutorial.Words do
  @behaviour Anemos.DataModel

  @impl true
  def keyword, do: "words"

  @impl true
  def parse(raw), do: {:ok, String.split(raw)}

  @impl true
  def eval(words, _context), do: {:ok, words}

  @impl true
  def transduce(words, _shape, "resource.transducer.upcase") do
    {:ok, Enum.map(words, &String.upcase/1)}
  end
  def transduce(_words, _shape, _name), do: {:error, :not_supported}
end

:ok = Anemos.Runtime.register_data_model(:anemos, Tutorial.Words)
```

A query engine uses the same behavior. For the `greeter` example:

```elixir
defmodule Tutorial.Greeter do
  @behaviour Anemos.DataModel

  @impl true
  def keyword, do: "greeter"

  @impl true
  def parse(raw), do: {:ok, String.trim(raw)}

  @impl true
  def eval(prefix, %{bindings: %{"name" => name}}) do
    {:ok, %{"line" => prefix <> " " <> name}}
  end

  @impl true
  def transduce(_data, _shape, _name), do: {:error, :not_supported}
end

:ok = Anemos.Runtime.register_data_model(:anemos, Tutorial.Greeter)
```

These handlers intentionally accept simple words, not arbitrary embedded
documents. The [data-model example script](examples/data_models.exs) installs
both, loads the relevant policies, and checks their answers.

## Keep credentials wrapped

A host verb returning a credential should return
`{:ok, Anemos.Secret.new(value, label: "non-sensitive-name")}`. Normal
inspection, interpolation, and logging redact the wrapped value. The
consumer deliberately unwraps it with `Anemos.Secret.expose/1` at the point
where the raw credential is needed.

Wrapping is opt-in. The runtime cannot infer that an arbitrary string is a
password. A label must not contain the credential. The wrapper prevents
accidental formatting disclosure; it is not encryption or a sandbox against
host code that reads the raw term. Custom connectors must consider serialization
carefully: serializing the underlying struct can expose its contents.

[Next: Deploying and operating policies](10-operation.md) · [Contents](README.md)

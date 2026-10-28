# `Anemos.Runtime.Watcher`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/watcher.ex#L1)

Keeps a directory of `*.rule` files deployed into a runtime.

Each file is a policy, named by its path relative to the directory. Saving
a file deploys it over the running version; deleting it unloads it. See
`Anemos.Runtime.load/3` for what a deploy keeps and what it replaces.

    {Anemos.Runtime, name: :anemos, watch: "/etc/anemos/policies"}

or, under your own supervisor, after the runtime:

    {Anemos.Runtime.Watcher, runtime: :anemos, dir: "/etc/anemos/policies"}

## A file that does not load

The version already running keeps running. The failure is logged once and
held for `status/1`. It is tried again on every pass, because what stopped
it may not be in the file: a rule name still held by a file that is about
to lose it, a feed handler the host has not registered yet. A file caught
half-written is this case too, and corrects itself on the next pass.

## A directory that is not there

Nothing is unloaded. A missing directory is not an empty one.

## Signatures

`<file>.sig`, if present, is passed to the load authority as the detached
signature (see `Anemos.Runtime.LoadAuthority.Signed`). Replacing it counts
as a change to the policy. It holds one signature, Base64, so it serves a
policy with a single declared signer; one that declares several has to be
loaded through `Anemos.Runtime.load/3`.

## Options

  * `:runtime` — the `Anemos.Runtime` name (required)
  * `:dir` — the directory to watch, searched recursively (required)
  * `:interval_ms` — how often to look, default 1000; `:manual` to look
    only when `scan/1` is called
  * `:name` — process registration name (optional)

# `status`

```elixir
@type status() :: :ok | {:partial, [Anemos.Runtime.load_failure()]} | {:error, term()}
```

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `scan`

```elixir
@spec scan(GenServer.server()) :: :ok
```

Looks at the directory now and deploys what changed.

# `start_link`

```elixir
@spec start_link(keyword()) :: GenServer.on_start()
```

Starts a watcher. See the moduledoc for options.

# `status`

```elixir
@spec status(GenServer.server()) :: %{required(String.t()) =&gt; status()}
```

The outcome of the last deploy of every policy file present.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

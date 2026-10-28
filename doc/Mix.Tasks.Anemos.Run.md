# `mix anemos.run`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/mix/tasks/anemos.run.ex#L1)

Parse and execute a `.rule` file against a given event.

    mix anemos.run priv/examples/garage-lights.rule \
      --event SENSOR_MOTION_DETECTED --context garage.motion.sensor

## Options

  * `--event`, `-e` — event name to dispatch (required)
  * `--context`, `-c` — the context path the caller occupies. `context`
    is a security boundary and fails closed, so a rule wrapped in
    `context "garage"` is unreachable until the caller says it is
    standing in `garage` or beneath it. Omitting this is not "run
    everything"; it is "I decline to say", and a declared boundary
    refuses that.
  * `--context-data KEY=VALUE` — external data that `?var` resolves
    against. Repeatable. This is a *different* thing from `--context`:
    one is where the caller stands, the other is what it brought with it.
  * `--stub-modules` — also register `Anemos.example_modules/0`, the
    demonstration doubles for `PDF`, `STRING`, `INFRA`, `SECRET` and
    `EVENT` that `priv/examples/` needs. Off by default: see
    `Anemos.example_modules/0` for why a `SECRET` double must be asked
    for rather than inherited.
  * `--help`, `-h` — print this usage summary.

## Exit status

`0` only when every operation succeeded. `1` on a usage error, an
unreadable file, a refused load, a parse or compile failure, or any
operation that returned an error — so the task can gate a script or a CI
step.

## The load is gated

The source goes through the same trust boundary as
`Anemos.Runtime.load/3` — the `:max_policy_bytes` ceiling and the
configured `Anemos.Runtime.LoadAuthority` (A-59). A refusal is reported
as such, named as the boundary rather than as a broken rule file, and
exits `1`. The default authority permits everything, so this changes
nothing until an operator configures one.

An empty result is reported as one of three distinct outcomes, because
they call for three different fixes: nothing subscribed to the event
(check the event name), something subscribed but the context boundary
denied it (pass `--context`), or a rule ran and every branch was false
(check the guards and the data). The previous single message, "No rules
matched", was wrong for all three — it describes zero *operations*.

# `describe`

```elixir
@spec describe(term()) :: String.t()
```

Renders one error for a policy author.

`Comn.Errors.ErrorStruct` carries `request_id` and `trace_id` for
correlating across services. Those are operator fields; `inspect/1` on
the struct — which is what the old fallback did — put them in front of
someone trying to fix a rule file, alongside every other nil field.

## Examples

    iex> err = Comn.Errors.ErrorStruct.new("anemos.runtime/unknown_module", nil, "Module PDF not found in registry")
    iex> Mix.Tasks.Anemos.Run.describe(%{err | trace_id: "abc123"})
    "Module PDF not found in registry (anemos.runtime/unknown_module)"

    iex> Mix.Tasks.Anemos.Run.describe("Unexpected token at line 3")
    "Unexpected token at line 3"

# `execute`

```elixir
@spec execute([String.t()]) :: {:ok | :error, [{:info | :error, String.t()}]}
```

The whole task minus the printing and the exit.

Returns `{:ok | :error, [{:info | :error, String.t()}]}`. Split out so
the CLI's behaviour — flag parsing, exit status, every message it can
emit — is testable without capturing IO or halting the VM. The absence
of that seam is a large part of why these defects survived.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

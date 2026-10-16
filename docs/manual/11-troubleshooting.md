# 11. Finding and fixing problems

When a policy does nothing, start by asking which stage had enough information
to decide. Did the source load? Was there a subscriber? Was it reachable?
Did a guard suppress evaluation? Did an operation fail? These are different
problems and need different fixes.

## Diagnose a one-shot run

`Anemos.run_report/2` adds reachability and error information to one-shot
execution:

```elixir
{:ok, report} = Anemos.run_report(source,
  event: "MOTION",
  context_path: "garage.sensor",
  context_data: %{"maintenance" => false})

Map.take(report, [:event, :subscribed, :reachable, :errors])
```

`subscribed` counts matching compiled handlers. `reachable` counts those
admitted by the arriving context. `operations` reports work produced;
`results` and `errors` distinguish successful results from operation failures.
A load/parse/compile failure returns `{:error, reason}` instead of a report.

Interpret an empty operation list in this order:

1. `subscribed == 0`: compare the exact event name to `when` clauses.
2. `reachable == 0`: compare the caller's context path to the declared boundary.
3. Otherwise, inspect guards, branch inputs, and intentionally empty bodies.

A handler containing only `let`/`set`, or an expression call whose answer is
unused, can execute without producing a visible operation. “No operations”
does not necessarily mean “no code ran.”

The CLI reports these broad cases and exits `1` for usage, read, load, parse,
compile, or operation errors. It exits `0` when dispatch completes without
reported operation errors, even if nothing subscribed or every branch was
skipped. An assertion with `held: false` is not an operation error either.
Use explicit result assertions in a host test when successful behavior
requires particular work to have happened.

## Ask what the runtime holds

```elixir
snapshot = Anemos.Runtime.describe(:anemos)
snapshot.rules
snapshot.conditions
snapshot.schedules
```

The snapshot reports policies, rules, current persistent bindings and dwell
state, conditions, capabilities, datasets, schedules, and module names. It is
an observation of a live system, not an atomic transaction over all workers.
Bindings are returned as values; wrapped secrets remain wrapped.

To ask what an event would reach without executing it:

```elixir
Anemos.Runtime.explain(:anemos, "MOTION",
  %{context_path: "garage.sensor"})
```

Rule outcomes include `:fires`, `:context_mismatch`, `:not_true` for a false
compound state, and `{:dwell, milliseconds}`. `:fires` means the dispatch
path is eligible. Explain does not evaluate guards, branches, or host calls,
so it cannot promise particular side effects.

`Anemos.Runtime.trace(:anemos, 20)` returns recent dispatches newest first.
Entries contain time, event, context path, rule steps, condition transitions,
result kinds, and duration. Handoffs and labeled emits appear in the steps.
The trace retains the last 200 dispatches. It summarizes most operation
values; log messages are deliberately retained as log text.

## Inspect from a policy

```anemos
rule inspect-system {
  when DEBUG {
    list rules
    list conditions
    list modules
    list events
    list policies
    list schedules
    show DEVICE
    explain DEVICE
    list DEVICE
    explain MOTION
    show ?payload
    infer ?payload
    trace ?payload
    exists ?optional_value
  }
}
```

`show` asks what something is. `explain` asks what it can do or who listens.
`list` asks for choices. A registered module answers through its description
or Comn callbacks; an unregistered event name can be inspected for listeners.
Policy-level catalogues and listener answers are limited to the asking rule's
own named policy. Anonymous loads share one inspection scope. Modules remain
visible across policies, and fact inspection uses the shared triple store.
Use the host's `Runtime.describe/1` for the runtime-wide inventory.
For a value expression, the operations report its value or inferred kind.
Answers are in dispatch results, with a `value` field, rather than necessarily
printed to the terminal as prose.

`trace ?payload` is a DSL value-inspection operation. It differs from the
host API `Runtime.trace/2`, which retrieves dispatch history. Treat explicit
value inspection as intentional disclosure, just as you treat `log`. Wrap
credentials in the host before they enter policy values.

## Common symptoms

| Symptom | Likely cause and next action |
| --- | --- |
| `mix: command not found` | Activate the toolchain in `.tool-versions`; check the terminal's `PATH` |
| No subscriber | Exact-name mismatch, no loaded policy, or statements placed outside a trigger |
| Subscriber but no reachable rule | Missing/wrong `context_path`; with map shorthand use outer `context` |
| `?value` is missing | Wrong payload shape/key, wrong sigil, or absent field; use string payload keys |
| `@name`/`$name` compile error | No matching `let`/`set` in the declaration; inspect the suggested sigil |
| Numeric comparison behaves oddly | CLI supplied a string; use typed host data and inspect with `infer` |
| A boolean guard always runs/skips | `"false"` is truthy; compare explicit values or fix producer types |
| `unknown_module` | Register the module before calling it; a persistent runtime does not inherit one-shot defaults |
| `unknown_verb` | Inspect module choices and check spelling and registration |
| `invalid_argument` | Match arity/types/schema; a path argument may have failed confinement |
| `unknown_dataset` | Dataset name/scope mismatch, failed initialization, or missing handler |
| `query_missing_binding` | An expected input is absent from `let`, `set`, and string-keyed context data |
| `unknown_data_model` | Register the query engine under its declared keyword |
| `query_failed` | Engine parse/evaluation failed or omitted the named return binding |
| Load says `partial` | Inspect every failure; some declarations installed but will not work |
| Timer armed but scoped body never runs | Built-in scheduled events have no context; use a scoped host event |
| Demand failed but later work happened | Current demand dispatch does not gate later operations |
| Fact query yields a map instead of rows | Value-position triple query is a descriptor in this version |
| Caller times out | Slow synchronous verb or excessive work; a timeout does not cancel it |

Structured errors are `Comn.Errors.ErrorStruct` values. Their stable `code`
identifies the category; `field` often names the declaration or argument.
The message explains the immediate problem. Request/trace IDs support
operator correlation. For readable author-facing output, use
`Mix.Tasks.Anemos.Run.describe(error)` rather than dumping the full struct.
Do not copy arbitrary raw host errors into user messages if they can contain
credentials or sensitive payloads.

## Recipe: ignore incomplete messages

```anemos
rule process-complete-reading {
  when READING {
    if not exists ?temperature { return }
    if ?enabled != true { return }
    log ?temperature
  }
}
```

This explicitly requires a present temperature and a boolean true flag.
It does not validate the temperature's numeric type; put that validation in
the event ingress or a host schema/verb if arithmetic follows.

## Recipe: one event updates state, another consumes it

```anemos
rule remember-mode {
  when MODE_CHANGED {
    set mode = ?mode
  }
  when REQUEST {
    if $mode == "active" {
      log "Processing is enabled"
    } else {
      log "Processing is disabled"
    }
  }
}
```

Before the first mode event, `$mode` is `nil`, so the disabled branch runs.
The state is shared by both handlers because they belong to one named rule.

## Recipe: two-stage processing with explicit payload

```anemos
rule receive-job {
  when SUBMITTED {
    if not exists ?job_id { return }
    nextevent VALIDATED with { job_id: ?job_id, checked: true }
  }
}

rule record-job {
  when VALIDATED {
    if ?checked == true {
      log ?job_id
    }
  }
}
```

The second rule receives the overlay and any remaining original fields.
For a real trust boundary, do not treat an arbitrary `checked` payload field
as proof of authorization: the host controls which producers can send each
event and context. This recipe demonstrates data handoff, not authentication.

## Test policies as programs

Start an isolated runtime, load named source, dispatch typed events, and
assert the results that matter. Check operation errors even when the outer
dispatch tuple is `{:ok, ...}`. For stateful logic, test a sequence including
reset/false reports rather than one happy event. For timers, observe delivery
with bounded waits instead of assuming millisecond-exact scheduling.

Run the manual's checks from the repository root:

```sh
mix test test/anemos/manual_test.exs
mix run docs/manual/examples/walkthrough.exs
mix run docs/manual/examples/data_models.exs
mix run docs/manual/examples/workshop.exs
```

Use `mix check` for the repository's formatting, strict Credo, and full test
suite. `mix docs` builds the manual alongside module API documentation.

[Next: A complete workshop application](12-workshop.md) · [Contents](README.md)

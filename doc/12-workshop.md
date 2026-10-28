# 12. A complete application: workshop temperature alerts

We have learned the pieces of Anemos separately. Now we will combine them in
one application: a workshop temperature monitor with a sensor allow-list,
a mute switch, a count of alerts, and a host service that receives alerts.
The example runs entirely in memory so you can inspect every decision.

The downloadable files are [workshop.rule](examples/workshop.rule) and
[workshop.exs](examples/workshop.exs). From the repository root:

```sh
mix run docs/manual/examples/workshop.exs
```

The script checks the scenario described below and prints
`Workshop scenario passed.` after every expected result has been observed.

## Write the input and output contracts first

The host promises to deliver these events:

| Event | Payload | Meaning |
| --- | --- | --- |
| `TEMPERATURE` | `sensor`: string; `celsius`: number | A sampled reading |
| `MUTE` | Empty map | Suppress temperature handling |
| `UNMUTE` | Empty map | Resume temperature handling |
| `REPORT` | Empty map | Report the number of alerts sent |

They arrive under `workshop.bench` or a descendant path. The accepted sensors
are `bench_a` and `bench_b`. An accepted reading at least 30 degrees requests
an alert unless muted. An unknown sensor logs a diagnostic. A missing
temperature logs a diagnostic and stops that handler.

The host supplies `ALERT::send(sensor, celsius)`. Its schema requires a string
and a number; it returns an acknowledgement map. The example verb appends
requests to an in-memory list. A deployed implementation could instead submit
requests to a service with its own delivery guarantees.

These contracts prevent a policy from guessing units, payload types, or what
“send” means. The host must also authenticate sensor identities and paths at
ingress. Membership in this sample dataset classifies a supplied sensor name;
it does not establish who produced a message.

## The policy

```anemos
data accepted_sensors {
  bench_a
  bench_b
}

rule workshop-alerts {
  context workshop.bench

  when MUTE {
    set muted = true
  }

  when UNMUTE {
    set muted = false
  }

  when TEMPERATURE unless $muted {
    if not exists ?celsius {
      log "Missing temperature"
      return
    }
    if ?sensor memberof(accepted_sensors) {
      if ?celsius >= 30 {
        let receipt = [ALERT::send ?sensor ?celsius]
        set sent = ($sent OR 0) + 1
        log @receipt
      }
    } else {
      log "Unknown sensor"
    }
  }

  when REPORT {
    log $sent OR 0
  }
}
```

`muted` and `sent` belong to the named rule and are shared by its handlers.
Before initialization they are `nil`. A missing mute flag lets the guard
pass. A missing sent count falls back to zero. Zero itself is truthy, so
subsequent `$sent OR 0` expressions preserve it correctly.

The alert verb is deliberately in value position. Its acknowledgement must
exist before the count increments. If the verb returns an error, evaluation
stops before the `set`, and the failed request is not counted. This does not
create a transaction with an external service: work may happen even if the
acknowledgement is lost. Real delivery needs an application request ID and
idempotency policy when retries are possible.

An accepted reading below 30 produces no operation. The rule still ran and
tested the reading. An empty result alone does not mean dispatch failed.

## The host service

The script starts an Agent to hold requests and registers this module:

```elixir
defmodule Tutorial.Alerts do
  use Anemos.Module, name: "ALERT"

  @impl Anemos.Runtime.Module
  def arg_schema("send"), do: [[type: :string], [type: :number]]
  def arg_schema(_verb), do: nil

  verb :send, fn [sensor, celsius], _context ->
    receipt = %{sensor: sensor, celsius: celsius}
    Agent.update(Tutorial.AlertSink, &(&1 ++ [receipt]))
    {:ok, receipt}
  end
end
```

`Tutorial.AlertSink` is a host process name. The interpreter knows only the
DSL name `ALERT`. The script supplies that registration at runtime startup,
loads the source as named policy `workshop.rule`, and checks the load returned
`:ok` before sending events.

## Follow a sequence

The scenario drives one persistent runtime through these observations:

| Input | Expected observation |
| --- | --- |
| `REPORT` | Log `0` |
| Accepted sensor at 22 | No alert |
| Accepted sensor at 31 | First alert; acknowledgement logged |
| Unknown sensor at 35 | Diagnostic; no additional alert |
| `MUTE`, then accepted sensor at 40 | Suppressed; no additional alert |
| `UNMUTE`, then accepted sensor at 32 | Second alert |
| `REPORT` | Log `2` |
| Accepted sensor at 50 from `garden.bench` | Context denied; no additional alert |

The host asserts both dispatch results and the sink's stored values. Checking
only log text would miss an accidentally sent alert. Checking only the sink
would miss incorrect count state or diagnostics.

The script also checks replacement: reloading identical named source retains
the count; changing the rule resets it. It then unloads `workshop.rule` and
checks that subsequent reports produce nothing. Unload removes declarations
and interpreter state, but does not erase the host's previously stored alerts.

## Change requirements deliberately

Suppose the workshop adds a second room. If both rooms reach this rule, they
share a mute switch and count. For independent room behavior, deploy separate
rule identities with separate contexts, or let a host service own keyed room
state. Adding a payload field alone does not partition `$` bindings.

Suppose an alert should occur only when temperature enters the hot state.
Repeated hot readings currently generate repeated alerts by design. Use a
condition with a threshold predicate for rising-edge behavior, and define the
reports that reset it. If several sensors feed one condition, they share its
state; decide whether each sensor needs an independent condition identity.

Suppose the threshold should be configurable. Add a numeric host payload
field and a documented default merged at ingress, or provide a settings query.
The producer contract is the right place to make units and types explicit.

Finally, suppose the count must survive VM restarts. Move it into a durable
host service and include it in acknowledgements. `set` is interpreter state
within a running runtime; records with retention requirements need durable
ownership.

## Exercises

1. Add an event that clears the count without changing mute state.
2. Add `bench_c` to the dataset and send a hot reading from it.
3. Supply string `"35"` as the temperature. What protects the host verb?
4. Reload the identical named policy and send `REPORT`. Then change its
   diagnostic text and reload. Which count survives?

Answers: (1) Add `when CLEAR_COUNT { set sent = 0 }` to the same rule.
(2) Membership admits it after deployment; context must still match.
(3) The numeric schema refuses the string. A mixed-type threshold comparison
is not sufficient validation; the failed value call aborts before incrementing.
(4) An unchanged rule keeps the count; a changed rule starts fresh and reports
zero through the fallback.

[Next: Language and API reference](reference.md) · [Contents](README.md)

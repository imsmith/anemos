# Anemos

Event-driven automation DSL on the BEAM. Define reactive policies that listen
for events, track conditions, gate on capabilities, and execute operations —
all in a concise, readable language.

## Quick Example

```
rule garage-lights-on {
  context "garage.motion.sensor" {
    when SENSOR_MOTION_DETECTED {
      [DEVICE::set "garage.lights" "on"]
    }
  }
}
```

## Richer Example

Conditions, capabilities, and rules compose. Here a network change condition
gates a DNS update rule that demands a capability before executing:

```
capability katachora-ddns-key {
  context infra.networking

  on demand {
    emit [SECRET::unlock(agent.did_meshid_z6MkAgent123.operator.security:did_key_67890)]
      as :katachora.ddns.key
  }
}

condition networkchanged {
  when (INFRA::ip4_addr_changed OR INFRA::ip6_addr_changed) {
    emit [EVENT::ip.addr.changed to channel(system.config.network)]
      as :{?hostname}.network.ip.addr.changed
  }
}

rule update-ddns {
  context infra.networking.dns

  when CONDITION_networkchanged {
    demand katachora-ddns-key

    let fqdn = ?fqdn
    let ipv4 = [INFRA::get_ip "eth0" type:ipv4]
    let ipv6 = [INFRA::get_ip "eth0" type:ipv6]
    let update = (:fqdn IN A ipv4) AND (:fqdn IN AAAA ipv6)

    emit [INFRA::ddns_update(:katachora.ddns.key, katachora.com, update)
          to channel(system.config.network.dns.ddns)]
      as ddns.update.:{?fqdn}
  }
}
```

More examples in `priv/examples/`.

## Integration

Anemos is a language interpreter, not an application. Start a blank runtime
in your supervision tree, then load modules and policies into it dynamically.

### Supervise the runtime

```elixir
children = [
  {Anemos.Runtime, name: :anemos}
]

Supervisor.start_link(children, strategy: :one_for_one)
```

### Register modules

Modules provide the implementation behind `[MODULE::verb]` commands.
Register them at any time — they accumulate.

```elixir
Anemos.Runtime.register(:anemos, "DEVICE", MyApp.Device)
Anemos.Runtime.register(:anemos, "INFRA", MyApp.Infra)
Anemos.Runtime.register(:anemos, "SECRET", MyApp.Secret)
```

### Load policies

Policies can be loaded one at a time or in bulk. They accumulate —
each `load/2` adds rules, conditions, and capabilities to the running
interpreter without replacing what's already there.

```elixir
Anemos.Runtime.load(:anemos, File.read!("policies/garage.rule"))
Anemos.Runtime.load(:anemos, File.read!("policies/ddns.rule"))
```

### Dispatch events

```elixir
{:ok, results} = Anemos.Runtime.dispatch(:anemos, "SENSOR_MOTION_DETECTED")
{:ok, results} = Anemos.Runtime.dispatch(:anemos, "EVENT", %{context_path: "garage"})
```

### Query state

```elixir
Anemos.Runtime.condition_state(:anemos, "networkchanged")
# => true | false | nil
```

### Set context data

Context data provides values for `?` variable resolution.

```elixir
Anemos.Runtime.put_context(:anemos, "infra.networking.dns.fqdn", "host.example.tld")
```

### One-shot API

For testing and scripts, `Anemos.run/2` parses, compiles, and dispatches
in a single call without a supervision tree:

```elixir
source = File.read!("priv/examples/garage-lights.rule")
{:ok, results} = Anemos.run(source, event: "SENSOR_MOTION_DETECTED")
```

### CLI

```bash
mix anemos.run <file.rule> --event <EVENT_NAME>
```

```bash
$ mix anemos.run priv/examples/garage-lights.rule --event SENSOR_MOTION_DETECTED
Dispatched SENSOR_MOTION_DETECTED -- 1 operation(s):

  [DEVICE::set "garage.lights" "on"]
```

## Language Constructs

### Rules

Rules subscribe to events and execute operations when they fire.

```
rule name {
  context scope.path {
    when EVENT_NAME {
      [MODULE::verb arg1 arg2]
    }
  }
}
```

### Conditions

Conditions are stateful processes. They evaluate incoming events and track
boolean state. When a condition transitions from false to true, it emits a
synthetic `CONDITION_<name>` event and executes its body as side effects.
Rules can subscribe to these with `when`, or query current state with `if`.

```
condition networkchanged {
  when (EVENT_A OR EVENT_B) {
    log "condition met"
  }
}
```

### Capabilities and Demand

Capabilities define named actions the system can perform. They are passive
until demanded. `demand` invokes a capability with PAM-style control flags:

- bare / `--requisite` (default) — must succeed, fail immediately if not
- `--required` — must succeed, but evaluate rest of stack before failing
- `--optional` — continue whether it succeeds or fails
- `--sufficient` — if succeeds, skip rest of stack

```
capability secret-key {
  context infra

  on demand {
    emit [SECRET::unlock key]
  }
}

rule use-key {
  when EVENT {
    demand secret-key
    demand audit-log --optional
  }
}
```

### Context

Context is an exclusionary boundary on the listener side. It defines the
workspace a rule or condition operates in, filtering which events it sees
and which capabilities are reachable.

Events are broadcast freely — contexts self-select what's relevant.

### Variables

Three sigils, two binding keywords:

| Sigil | Meaning | Created by |
|-------|---------|------------|
| `?name` | Dereference — resolve from external context data | Environment |
| `@name` | Immutable, ephemeral — dies when execution ends | `let` |
| `$name` | Mutable, persistent — survives across firings | `set` |

The keyword determines the kind: `let fqdn = ?fqdn` creates `@fqdn`.
The sigil is how you read it back.

### Loops

Iterate over collections or repeat while a condition holds.

```
; Iterate a list
for item in ?items {
  log @item
}

; Repeat while condition is true (safety limit: 10,000 iterations)
while $count > 0 {
  log $count
  set count = $count - 1
}

; each/every are aliases for for-in, foreach iterates module results
each record { log @record }
foreach FILE::list { log @item }
```

Loop variables are bound as `@var` (immutable, ephemeral). `$set` bindings
inside loops persist across iterations.

### Flow Control

Control execution flow within and across rules.

```
; Early exit — stops the current handler
return
done

; Transition to another when block in the same rule
nextevent STEP_TWO

; Dispatch to a different rule by name
nextrule other-rule
```

`return` and `done` stop execution immediately — statements after them
are not reached. `nextevent` re-dispatches within the same rule's when
blocks. `nextrule` invokes another rule directly, bypassing event
subscription matching.

### Scheduled Triggers

`at` blocks are clock-driven event sources. They fire at specific times,
on intervals, or on recurring schedules.

```
; One-shot
at 13:00 { log "lunch" }

; Interval
at interval(5min) { log "tick" }

; Recurring
at 09:00 every day { log "morning" }
at 11:00 every weekday { log "standup" }
at 09:00 every monday { log "week start" }

; Prefixed forms
at TIME_1300 { log "lunch" }
at DATE_2026.04.15 { log "deadline" }
at DAY_friday { log "weekend" }

; Natural language dates
at NLD_tomorrow { log "due" }
at NLD_next.wednesday { log "standup" }
at NLD_end.of.month { log "reports" }
at NLD_next.week { log "new sprint" }
```

Supported NLD expressions: `today`, `tomorrow`, `yesterday`,
`next.monday`..`next.sunday`, `next.week`, `next.month`, `next.year`,
`end.of.month`, `end.of.week`.

`at` blocks work inside both rules and conditions. In a condition,
the condition becomes true at the scheduled time.

### Modules

Modules are external — registered dynamically, never defined in policy.
`MODULE::verb` is the dispatch syntax. Policies declare what to do;
modules provide how.

```
[DEVICE::set "light" "on"]
[INFRA::get_ip "eth0" type:ipv4]
```

Define modules with the `Anemos.Module` macro — a declarative mapping
of verbs to functions:

```elixir
defmodule MyApp.Anemos.Secret do
  use Anemos.Module, name: "SECRET"

  verb :unlock, &Comn.Secret.unlock/2
  verb :rotate, fn args, ctx -> Comn.Secret.rotate(hd(args), ctx[:tenant]) end
end
```

Register with just the module — name comes from the macro:

```elixir
Anemos.Runtime.register(:anemos, MyApp.Anemos.Secret)
```

### Emit

Emit operations produce output. With a label, the label is re-dispatched
as an event through the interpreter — other rules can react to emits.

```
emit [EVENT::fire] as :my.event
emit state [SENSOR::reading] to channel(telemetry) as :sensor.update
```

### Triple Patterns

Triple patterns are RDF-like subject-predicate-object facts. Two syntaxes
for two operations:

**Assert** (arrows — create a fact):
```
let [:p001 -> :knows -> :p002]
let [:p001 -> :worksOn -> :proj1]
```

**Query** (spaces — match against existing facts):
```
[?a :worksOn ?p]              ; binds ?a and ?p from matches
[:p001 :knows :p002]          ; exact match check
```

Facts accumulate in a triple store within the runtime. Query variables
bind to matched values.

### Expressions

Full operator precedence (14 levels, matching the language spec):

```
2 + 3 * 4          ; 14, not 20 — multiplication binds tighter
(2 + 3) * 4        ; 20 — parentheses override
1 == 1 and 2 == 2  ; true — comparison before logical
5 & 3              ; 1 — bitwise AND
1 << 3             ; 8 — left shift
```

Arithmetic (`+`, `-`, `*`, `/`, `%`), bitwise (`&`, `|`, `^`, `<<`, `>>`, `~`),
comparison, logical, and membership operators all at correct precedence.

### Event Protocol

Implement the `Anemos.Event` protocol on your application's event types
for zero-translation dispatch:

```elixir
defimpl Anemos.Event, for: MyApp.MQTTMessage do
  def name(msg), do: msg.topic |> String.upcase() |> String.replace("/", "_")
  def context(msg), do: msg.topic
  def payload(msg), do: msg.body
end

# Dispatch directly — no wrapping
Anemos.Runtime.dispatch(:anemos, mqtt_message)
```

The protocol has three callbacks: `name/1` (for rule matching), `context/1`
(for listener filtering), `payload/1` (for `?` variable resolution).
String dispatch still works for simple cases.

### Channel Connectors

Emits that target a channel publish through a pluggable connector.
The connector bridges Anemos to your messaging infrastructure —
Phoenix.PubSub, NATS, AMQP, or anything else.

```elixir
# Implement the behaviour
defmodule MyApp.PubSubChannel do
  @behaviour Anemos.Channel

  @impl true
  def publish(channel, envelope) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, channel, {:anemos, envelope})
  end
end

# Connect it
Anemos.Runtime.connect(:anemos, MyApp.PubSubChannel)
```

Default connector: `Anemos.Channel.Logger` — logs all emits so they're
never silent.

Every published message is an `%Anemos.Envelope{}`:

| Field | Description |
|-------|-------------|
| `type` | `:state`, `:effect`, `:stream`, or nil |
| `payload` | The emitted value |
| `source` | Rule name and context (`"rule@context.path"`) |
| `timestamp` | UTC time of emission |
| `label` | Symbolic handle from `as :label` |
| `channel` | Destination channel path |
| `signature` | Reserved for cryptographic signing |

## Architecture

```
                    ┌──────────────────────────────────────────┐
                    │            Anemos.Runtime                │
                    │            (Supervisor)                  │
                    └──┬──────────┬──────────┬──────────┬──────┘
                       │          │          │          │
              ModuleRegistry  ContextStore  Dispatcher  Scheduler
              (Agent)         (Agent)       (GenServer) (GenServer)
                                               │          │
                              ┌────────────────┼───┐      │
                              │                │   │   AT_* events
                     ConditionServer    CapServer  Rule    │
                     (GenServer×N)     (GS×N)    Index ◄───┘
                                          │
                                     TripleStore
                                      (Agent)
```

Policies are loaded via `Anemos.Runtime.load/2`, which parses, compiles,
and merges new declarations into the running dispatcher. The scheduler
manages timers for `at` blocks and dispatches synthetic `AT_*` events.
Multiple policies accumulate. Log operations go through Elixir Logger.
Emits with labels re-dispatch as events. Condition side effects fire on
transition. `set` bindings persist across event firings.

## Project Status

**v0.1.0** — Supervisable interpreter with dynamic policy and module loading.
Conditions, capabilities, demand gating, context filtering, variable binding,
emit re-dispatch, scheduled `at` triggers, triple patterns, full operator
precedence (14 levels), channel connectors with message envelopes, NLD
natural language dates, loops (`while`, `for`, `each`, `every`, `foreach`),
flow control (`return`, `done`, `nextevent`, `nextrule`), Logger integration,
`Anemos.Module` macro, and `Anemos.Event` protocol all work end-to-end.
Module backends are stubs — bring your own implementations.

## Docs

```bash
mix docs
open doc/index.html
```

Interactive playground:

```bash
livebook server notebooks/playground.livemd
```

## License

AGPL-3.0

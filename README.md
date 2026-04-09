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

## Install and Run

Requires Elixir 1.19+ / OTP 28+.

```bash
git clone <repo-url> && cd anemos
mix deps.get
mix compile
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

### Programmatic API

```elixir
source = File.read!("priv/examples/garage-lights.rule")
{:ok, results} = Anemos.run(source, event: "SENSOR_MOTION_DETECTED")
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

Conditions are stateful GenServers. They evaluate incoming events and track
boolean state. When a condition transitions from false to true, it emits a
synthetic `CONDITION_<name>` event. Rules can subscribe to these with `when`,
or query current state with `if`.

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

### Modules

Modules are external — registered at startup, never defined in policy.
`MODULE::verb` is the dispatch syntax. Policies declare what to do;
modules provide how.

```
[DEVICE::set "light" "on"]
[INFRA::get_ip "eth0" type:ipv4]
```

## Pipeline

```
source.rule → Lexer → Parser → Compiler → Dispatcher
                                   ↓
                          ConditionServer (GenServer)
                          CapabilityServer (GenServer)
                          ContextStore (Agent)
```

1. **Lexer** — NimbleParsec tokenizer
2. **Parser** — recursive descent, produces typed AST
3. **Compiler** — compiles rules, conditions, and capabilities into process specs and closures
4. **Dispatcher** — routes events to conditions and rules, resolves demands through capabilities
5. **Module Registry** — maps `MODULE` names to Elixir implementations

## Project Status

**v0.1.0** — Core pipeline is functional. Conditions, capabilities, demand
gating, context filtering, variable binding, emit re-dispatch, and Logger
integration all work. Log operations go through Elixir Logger. Emits with
labels re-dispatch as events. Condition side effects fire on transition.
Module backends are stubs (DEVICE, FILE echo back structures) — no real
I/O integrations yet.

## Docs

```bash
mix docs
open doc/index.html
```

## License

AGPL-3.0

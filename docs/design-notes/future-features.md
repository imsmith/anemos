# Future Features -- NOT in v0.1.0

## Language Spec Source

- `097 Orders of the System/96 Standards/Automation DSL - Language Specification.md`

Features defined in the language specification that are excluded from the v0.1.0 implementation. Each will need its own design, implementation, and testing pass.

---

## Trigger Blocks

### `at` -- Time-Based Triggers

```
at TIME_0700 { ... }
at interval(30s) { ... }
at 9:00AM every weekday { ... }
```

Supports time literals (`TIME_HHMM`, `DATE_YYYY.MM.DD`, `DAY_weekday`, natural language dates), intervals, and recurrence patterns.

### `on` -- Invocation Triggers

```
on boot { ... }
on demand { ... }
on keypress "ctrl+shift+r" { ... }
```

Fires on system lifecycle events, explicit demand invocations, or keypress bindings.

### `it` -- Modal Logic Triggers

```
it <modal-ref> {
  by <identity-ref> that { ... }
}
```

Bridges the automation DSL to the CommonRule modal logic system. Fires based on belief states, knowledge assertions, obligations. See [modal-logic.md](modal-logic.md).

### `as` -- State Transitions

```
as "deploying" { ... }
```

Executes statements within a named state context. Enables state-machine-style rule composition.

### `with` -- Concurrent/Group Execution

```
with each server in $fleet { ... }
with agents [:deploy, :monitor] { ... }
with servers tagged "production" { ... }
```

Iterates over collections, agent groups, or tagged sets. Supports concurrent execution blocks.

---

## Orchestration

### `flow` -- Multi-Rule Orchestration

```
flow deploy-pipeline {
  nextrule validate-config with { env: "prod" }
  nextrule deploy-service
  nextrule verify-health
}
```

Sequences multiple rules into a coordinated pipeline. Uses `nextrule` for inter-rule transitions with argument passing.

---

## Data and Query

### Triple Patterns and Inference

```
let [:p001 -> :knows -> :p002]
condition collab {
  if [?a :worksOn ?p] && [?b :worksOn ?p]
  then [?a :collaboratesWith ?b]
}
```

Subject-predicate-object patterns for knowledge representation, inference rules in conditions, and filter queries.

### Pipeline Statements (`|>`)

```
data |> filter expr |> map ?x { ... } |> reduce acc ?x |> emit [CMD]
```

Functional pipeline composition with filter, map, reduce, and emit stages.

---

## Guard Modifiers

### `unless`

```
when SENSOR_MOTION for 5min unless $override == true { ... }
```

Negative guard -- block does not fire if the unless-expression is true.

### `until`

```
when EVENT unless $done until $timeout > 30s { ... }
```

Temporal guard -- block stops firing once the until-expression becomes true.

---

## Runtime Features

### Hot Reload

Files are watched for changes; modifications trigger hot reload of rules. Exact mechanism TBD.

### Dry-Run Mode

Execute rule logic without side effects. Useful for testing and validation.

### Broadway Integration

Use Broadway (Elixir) for backpressure-aware, concurrent event processing in the messaging substrate.

---

## Security and Trust

### Cryptographic Signing — DID identifiers and the encoding suite

**Partly landed.** Detached Ed25519 signature verification shipped with A-05:
`Anemos.Runtime.LoadAuthority.Signed` verifies a signature carried in the
`:authorization` option against a public-key keyring, all declared signers are
required, and `unsigned_policy` decides what happens to a source claiming none.
A-60 then made `signed_by` a source-level declaration, so a file declaring no
rule can still carry provenance:

```
signed_by :operator

condition night { ... }
```

What remains future is the **identifier and encoding suite**, not the
mechanism:

- **DID (Decentralized Identifier) signers** — `signed_by :operator.did`. Today
  a signer is an opaque name looked up in a keyring; resolving a DID to a key
  needs a resolver and a trust policy for the resolution itself.
- **Algorithms beyond Ed25519** — `sha256`, `sha384`, `sha512`. `TrustStore`
  refuses a key whose algorithm it does not verify rather than accepting it
  unchecked, so adding one is additive.
- **Encodings beyond raw and Base64** — `base58`, `base64url`.

### Predefined Conditions

Named, reusable boolean conditions for common scenarios:

- `daytime`, `nighttime`
- `home`, `away`
- `weekday`, `weekend`
- Custom user-defined conditions

---

## Module System Extensions

Full verb metadata with typed inputs/outputs, idempotency flags, purity annotations, and effect classification (`state`, `io`, `message`, `none`). Reversibility tracking for undo operations.

## Introspection

Full suite: `show`, `list`, `graph`, `trace`, `explain`, `exists`, `infer`, `assert`. These provide runtime visibility into rule state, event graphs, and policy evaluation.

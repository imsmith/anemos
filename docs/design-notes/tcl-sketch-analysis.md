# Tcl Sketch Analysis — Gap Inventory

Analysis of pre-spec Tcl design sketches against the Automation DSL Language Specification and Anemos v0.1.0 implementation. These sketches represent design thinking that preceded the formal spec and surface features the spec doesn't cover.

Source files: `~/toolboxes/*.tcl` and `~/github/anemos/*.tcl`

## Files Analyzed

### 1. bot_detected.tcl

**Location:** `~/toolboxes/bot_detected.tcl`

Closest to valid Anemos of all sketches. Two standalone `when` blocks implementing randomized bot countermeasures.

```tcl
when BOT_DETECTED {
    set action [random.int(1...8)]
    switch $action {
        1 [HTTP::Reply [BOT::random_method] [BOT::lorem_ipsum_payload]]
        2 wait [random.int(1000...5000)], [HTTP::Reply ...]
        3 drop
        ...
    }
}
```

**Gaps:**

- `switch` statement — not in spec; would need `if`/`elseif` chains
- `wait` — delay/sleep primitive not in spec
- `drop` — bare keyword action (network policy domain)
- Range literals `1...8` — not in spec
- Standalone `when` at top level — spec requires `when` inside `rule`
- Comma-separated command args — spec uses space-separated
- `random.int()` — function call with parens, not `[MODULE::verb]` syntax

### 2. condition.tcl

**Location:** `~/toolboxes/condition.tcl`

Rich sketch exercising conditions, capabilities, rules, `it` blocks, pipelines, and publish/subscribe destinations. Most feature-dense of all files.

**Constructs near-valid:**

- `condition name { if [triple] then [triple] }` — in spec
- `capability name { context path  on demand { ... } }` — in spec, implemented
- `rule` with `context`, `when CONDITION_name`, `demand` — in spec
- `emit [MODULE::verb] to channel(...)` — in spec, implemented
- `it is_required by` — `it` block is in spec EBNF (not implemented)

**Gaps:**

- `filter :name { pattern } |> map |> reduce |> emit` pipeline — appears in 4 examples. Most-wanted missing feature.
- `sign ... with signer` — crypto signing as pipeline stage
- `capability(?arg1, ?arg2) =>` — function-call-style invocation with arrow
- `at interval(5 minutes)` — repeating trigger; spec has `at` but not `interval()`
- `CONDITION_name` — spec uses `CONDITION::name` (double colon, not underscore)
- `on update` — spec only defines `on demand`
- `classify :content { if ... then ... }` — inline classification block
- Destination types: `webhook()`, `xmpp()`, `darkweb(onion://...)`, `volume()`, `ipfs()` — spec only has `channel()`, `service()`, `systemd()`, `self`
- Storage targets: `table`, `column`, `row`, `vector` — not in spec
- `with metadata.template(...)` — `with` as command modifier (spec has `with` as trigger block only)
- `SENSOR::reading(sensor:light) > 1000` — function-call with parens in expression
- `@CONTENT classified as :porn` — `classified as` operator
- `it` modal body internals: `that "..."`, URL reference, `uuid:` — not defined in spec

### 3. context.tcl

**Location:** `~/toolboxes/context.tcl`

Context as first-class filtering mechanism, inline conditions, function definitions, shell execution.

```tcl
context (filter "updates available" in meta.debian.12) {
    when FILTER_MATCH {
        run function.update.linux
    }
}
```

**Gaps:**

- `context (filter ... in ...)` — dynamic filter expression as context path
- `package ... to ... as ...` — archive/packaging action
- `run function.name` — function invocation statement
- Inline `condition` inside `rule` body — spec only allows top-level conditions
- `TIME::hour` without brackets — spec requires `[MODULE::verb]`
- Backtick shell execution: `` let distro `lsb-release -a` ``
- Dotted property access: `distro.id`, `distro.release`
- String interpolation in paths: `meta.$distribution.$version`
- `set` without `=` as flag-setting
- Condition name as `at` time-spec: `at maintenance_window`
- `deffunc` — function definition block with typed parameters
- `cond do ... end` — Elixir-style multi-branch conditional
- `run command("...")` — shell execution
- `Telemetry.info(...)` — direct module call with parens
- Boolean literals `true`/`false` — not in lexer

### 4. stop-data-extraction-policy.tcl

**Location:** `~/github/anemos/stop-data-extraction-policy.tcl`

Network security policy with static/dynamic data sets and PAM-style policy evaluation.

**Gaps:**

- `data` blocks — static lists (`reserved-ips`, `reserved-domains`, `historical-tlds`)
- `data dynamic { subscribe webhook/rss/amqp/git ... }` — dynamic data with subscription sources
- `policy` block — numbered match rules with `sufficient`/`requisite` annotations (PAM model)
- `deny`/`permit` statements
- `memberof()` operator
- `when [CONNECTION::init]` — command expression as event (not MODULE_ID)
- `forward` statement
- `||` as alternation inside `eq` comparisons

### 5. ingress-traffic-policy.tcl

**Location:** `~/github/anemos/ingress-traffic-policy.tcl`

Same constructs as stop-data-extraction-policy: `data`, `rule` with `deny`/`permit`/`memberof`, `policy` block. References rules from the other policy file.

### 6. pg-cluster.tcl

**Location:** `~/toolboxes/pg-cluster.tcl`

Infrastructure topology DSL — completely different language concern.

**Gaps (entire file is out of scope):**

- `unit` — infrastructure grouping
- `node` — compute node declaration with properties
- `link` — network link between nodes
- `service` — service definition
- `servicekit` — service bundle reference
- `properties {}` — key-value property blocks
- Array literals `["a", "b"]`
- `cpu:ram = "1:4096"` — compound keys
- Range `{1..5}`

### 7. rule.tcl

**Location:** `~/toolboxes/rule.tcl`

Design sketchpad mixing multiple language concerns in one file.

**Near-valid fragment:**

```
rule publish-api {
    context system.discovery
    when API::update {
        emit [API::update_notification{...}] to channel(system.updates) as update-notification
    }
}
```

Skeleton works; complex emit payload with `{:id, :name, ...}` block args and `#` interpolation doesn't.

**Gaps (beyond the rule):**

- `layout` blocks — UI layout DSL
- `query` blocks with `expect`/`return` — query language
- `data` blocks with embedded EDN, XML, Elixir, SQLite formats
- `transclude to shape(...) with resource.transducer.* as fact` — data transformation pipeline
- EDN-style knowledge graph triples
- `message` block

---

## Consolidated Gap Inventory

### Tier 1: High frequency across sketches, core to the language vision

| Feature | Files | Notes |
|---------|-------|-------|
| `filter \|> map \|> reduce \|> emit` pipeline | condition.tcl, context.tcl | Functional data transformation chain. `\|>` is mentioned in spec but undefined. Most-wanted missing feature. |
| `data` blocks (static and dynamic) | stop-data-extraction, ingress-traffic, rule.tcl | Static lists, dynamic subscriptions (webhook, RSS, AMQP, git). Data definition layer that neither Anemos nor CommonRule addresses. |
| `switch`/`cond` multi-branch | bot_detected, context.tcl | `if`/`elseif` chains are verbose. Pattern-matching dispatch needed. |
| Extensible destination types | condition.tcl | `webhook()`, `xmpp()`, `volume()`, `ipfs()`, `darkweb()`. Spec's closed enum (`channel`/`service`/`systemd`/`self`) is insufficient. |
| Property access on variables | context.tcl, condition.tcl | `distro.id`, `?site.ip`. Variables are opaque in spec; need dotted traversal. |

### Tier 2: Important but narrower scope

| Feature | Files | Notes |
|---------|-------|-------|
| `policy` blocks (PAM-style evaluation) | stop-data-extraction, ingress-traffic | Numbered rules, `sufficient`/`requisite` disposition. CommonRule territory. |
| `deny`/`permit`/`memberof` | stop-data-extraction, ingress-traffic | Policy action primitives. CommonRule territory. |
| `deffunc` / function definitions | context.tcl | Reusable functions with typed parameters and return values. `capability` is closest but not general-purpose. |
| Inline `condition` inside `rule` | context.tcl | Spec only allows top-level conditions. Sketches want rule-scoped conditions. |
| Shell execution (backticks, `run command()`) | context.tcl | No shell-out primitive in spec. |
| `at interval()` repeating triggers | condition.tcl | Spec has `at` for time specs but no repeating interval. |
| `wait`/delay primitive | bot_detected | No delay/sleep in spec. Runtime scheduling concern. |
| Range literals (`1...8`, `{1..5}`) | bot_detected, pg-cluster | Not in spec or lexer. |
| Boolean literals `true`/`false` | context.tcl | Not in lexer. |
| Context as filter expression | context.tcl | `context (filter ... in ...)` — dynamic subscription, not static path. |

### Tier 3: Domain-specific or separate language concerns

| Feature | Files | Notes |
|---------|-------|-------|
| Infrastructure topology (`unit`/`node`/`link`/`service`) | pg-cluster | Declarative resource graph. Separate DSL. |
| UI layout (`layout`/`form`/`image`) | rule.tcl | Separate concern entirely. |
| Query language (`query`/`expect`/`return`) | rule.tcl | SPARQL-like query blocks. Separate concern. |
| Knowledge graph triples (EDN-style) | rule.tcl | Related to spec's triple patterns but different syntax. |
| Data format embedding (EDN, XML, SQL) | rule.tcl | Multi-format data ingestion with `transclude`/`shape`/`transducer`. |
| Crypto signing as pipeline stage | condition.tcl | `sign ... with signer`. Could be a module verb instead. |
| `it` modal body internals | condition.tcl | `that`, URL reference, `uuid:` inside `it` blocks. Spec has the block but not the body grammar. |

---

## Language Concern Boundaries

These sketches collectively surface 6+ distinct language concerns:

1. **Automation/orchestration** (Anemos) — event-driven rules, triggers, actions. The spec covers this.
2. **Policy evaluation** (CommonRule) — deny/permit, sufficient/requisite, match chains. Not in spec.
3. **Data definition** — static lists, dynamic subscriptions, format transduction. Not in spec.
4. **Infrastructure topology** — nodes, links, services, properties. Separate DSL.
5. **Query** — expect/return, pattern matching against knowledge stores. Not in spec.
6. **UI layout** — forms, images, positioning. Separate DSL.

The open question: do concerns 1-3 (and possibly 5) converge into one grammar, or stay as separate DSLs sharing runtime infrastructure (BEAM, module registry, event bus)?

---

## Vault Sources

- Language spec: `097 Orders of the System/96 Standards/Automation DSL - Language Specification.md`
- CommonRule: `097 Orders of the System/40 Doctrine/commonrule.md`
- Triangle of Intent (Anemos/CommonRule/Sentinel relationship): `097 Orders of the System/99 Conversations/XAML vs XUL Comparison.md`

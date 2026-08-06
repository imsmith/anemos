# Issues

Tracked here until they migrate to a real issue tracker.

Entries filed 2026-08-04 came from the as-built architecture review. Entries filed
2026-08-06 came from the five-analyst forensic audit in `.legacy/docs/`; findings
marked **[REPRODUCED]** there were demonstrated against a running system, not
inferred from reading.

**Trust model decision, 2026-08-06:** Anemos is a **multi-tenant policy engine**.
Policy text is untrusted input. That makes A-01 through A-05 product requirements
rather than hardening, and it is the reason `signed_by` must be implemented rather
than removed.

## Status register

| ID | Severity | Issue | Status |
| --- | --- | --- | --- |
| A-01 | CRITICAL | Child crash silently discards every loaded policy | **Fixed** — two-tier supervision + `PolicyStore`; 12 regression tests |
| A-02 | CRITICAL | Unbounded event recursion never terminates | **Fixed** — depth ceiling 10,000, structured error; 5 regression tests |
| A-03 | CRITICAL | Process dictionary leaks operations between unrelated rules | Open |
| A-04 | CRITICAL | Every `condition` fires unconditionally | Open |
| A-05 | HIGH | `signed_by` parsed and never verified | Open |
| A-06 | HIGH | Context isolation fails open, two ways | **Fixed** — `ContextScope.within?/2`, segment-aware and fail-closed |
| A-07 | HIGH | Capability context scoping is decorative | **Fixed** — enforced in the server; denial bypasses PAM flags |
| A-08 | HIGH | Unbounded atom creation can kill the node | **Fixed** — compile-time string maps; 10 regression tests assert the atom table does not grow |
| A-09 | HIGH | Default connector logs secrets in plaintext | **Fixed** — `Redact.summarize/1` in the connector; `Anemos.Secret` wrapper added |
| A-10 | HIGH | `ModuleRegistry` verb routing can be hijacked | **Mitigated** — write-once + logged; not authorization, see entry |
| A-11 | HIGH | No input validation between DSL and host verbs | Open |
| A-12 | HIGH | `load/2` has no trust boundary | Open |
| A-13 | MEDIUM | Demand fails open on unknown capabilities | Fixed — pending suite verification |
| A-14 | MEDIUM | Unbounded timers permit resource exhaustion | Fixed — pending suite verification |
| A-15 | MEDIUM | Duplicate `load/2` doubles execution; no unload | Open |
| A-16 | MEDIUM | `nextrule`/`nextevent` discard state | **Fixed** — state threaded through `execute_op/4`; args gap is A-51 |
| A-17 | MEDIUM | Sibling `when` block destroys armed dwell state | Open |
| A-18 | MEDIUM | `Anemos.run/2` leaks 4 processes per call | **Fixed** — `Runtime.Standalone` with explicit teardown; 2 regression tests |
| A-19 | MEDIUM | Same-time `at` blocks collide and leak timers | Open |
| A-20 | MEDIUM | Schedules that can never fire report `:ok` | Fixed at the scheduler; `load/2` propagation pending (see A-22) |
| A-21 | MEDIUM | Internal error detail returned to callers | Open |
| A-22 | MEDIUM | Three incompatible error representations | Partially fixed — `load/2` now propagates partial failure; the three representations remain |
| A-23 | MEDIUM | `TripleStore` unbounded list, O(n) insert | Open |
| A-24 | MEDIUM | `DataStore` scope discriminators inconsistent; cleanup unreachable | Open |
| A-25 | MEDIUM | Unbound variables silently resolve to `nil` | Open |
| A-26 | MEDIUM | Subscription failures logged and dropped (fail-open) | Partially fixed — unhandled protocol now surfaces through `load/2`; `memberof` still fails open |
| A-27 | LOW | No CI, no linting, no static analysis | Open |
| A-28 | LOW | `comn` path dependency makes the repo unbuildable | Open |
| A-29 | LOW | `TODO.md` contradicts the README and the code | Open |
| A-30 | LOW | Two of three shipped examples do not work | Open |
| A-31 | LOW | Parser diagnostics contradict stated ergonomics principle | Open |
| A-32 | LOW | Repository hygiene | Open |
| A-33 | MEDIUM | `Anemos.Module` documents two functions that do not exist | Open |
| A-34 | MEDIUM | Format `data` blocks are silently discarded | Open |
| A-35 | MEDIUM | `compile_query/1` is an unmarked stub; `query_blocks` never read | Open |
| A-36 | LOW | Spec/test drift on transducer naming | Open |
| A-37 | LOW | `compiler.ex:453` type confusion latent in dwell duration | Open |
| A-38 | LOW | DST exposure is wider than `scheduler.ex` — `nld.ex` too | Open |
| A-39 | HIGH | `nextrule` bypasses context filtering and the dwell state machine | **Fixed** — `dispatch_rules/5` is now the only path into a handler |
| A-51 | MEDIUM | `nextrule` args are dropped in the parser; `BlockArgs` never constructed | Open |
| A-52 | MEDIUM | `dispatcher.ex` still discloses payloads in three places | Open |
| A-53 | MEDIUM | CLI has no `--context`, so every scoped example now prints "No rules matched" | Open |
| A-40 | MEDIUM | Persistent `set` bindings destroyed by a dispatcher restart | Open |
| A-41 | MEDIUM | Armed dwell timers vanish on restart and never re-arm | Open |
| A-42 | MEDIUM | Condition state resets to false on restart, causing a double-fire | Open |
| A-43 | MEDIUM | `ModuleRegistry` registrations have no durable backing | Open |
| A-44 | MEDIUM | Parser accepts specs the runtime cannot dispatch — deferred crash | Partially fixed — two instances closed; the class is unaudited |
| A-45 | LOW | Lexer post-processing errors report column 1, violating the stated contract | Open |
| A-46 | HIGH | The language has no boolean literals; `== true` is inverted from intent | Open |
| A-47 | MEDIUM | Compound `AND` event triggers behave as `OR` | Open |
| A-48 | MEDIUM | `until` on a condition trigger cannot latch | Open |
| A-49 | MEDIUM | Multiple trigger blocks in one condition run each other's side effects | Open |
| A-50 | MEDIUM | Condition-body operations are computed and dropped; needs dispatcher wiring | Open |
| L-01 | — | `RuleSupervisor` is dead code that ships in the published docs | **Resolved** — wired as the per-rule tier alongside `StoreSupervisor` |
| L-02 | — | `DataModelRegistry` is exercised only by its own tests | **Diagnosis corrected** — premise was wrong; keep the module, real defects split to A-34/A-35 |
| L-03 | — | `Anemos.Application` starts no supervision tree | **Resolved** — documented as a library application |

Findings in the sibling `comn` repository are tracked separately in
`.legacy/docs/comn-findings.md` and are out of scope for this repository.

---

## A-01 — Child crash silently discards every loaded policy

**Filed:** 2026-08-06 · **Severity:** CRITICAL · **[REPRODUCED]**

### Symptom

`Dispatcher.init/1` (`lib/anemos/runtime/dispatcher.ex:96-129`) calls `start_link` on
every `ConditionServer`, every `CapabilityServer`, the `TripleStore`, the `DataStore`,
and the `SubscribableRegistry`. These become *linked* processes of the dispatcher,
supervised by nobody. `Process.flag(:trap_exit, ...)` appears nowhere in `lib/`.

`ConditionServer.handle_cast/2` (`lib/anemos/runtime/condition_server.ex:70`) invokes a
user-supplied evaluator closure with no rescue, so any exception in a policy's condition
expression kills the condition server, which kills the dispatcher.

The dispatcher is then restarted by its supervisor with the child spec at
`lib/anemos/runtime.ex:172-177` — `rules: [], conditions: [], capabilities: []`.

```text
ops before crash:      1
same dispatcher pid?   false
ops after crash:       0
```

Every policy loaded via `Anemos.Runtime.load/2` is gone. `dispatch/3` returns `{:ok, []}`
forever, which is byte-identical to "no rule matched". No error, no log, no supervisor
message the host can observe.

### Why it happens

Process lifecycles are owned by the process that also runs untrusted closures. The
`DynamicSupervisor` that would fix this — `Anemos.Runtime.RuleSupervisor` — was written
and never wired in (L-01).

### What should change

Two supervision tiers, per the 2026-08-06 design decision: a `StoreSupervisor` for
stores-as-infrastructure, and `RuleSupervisor` as a per-rule tier for rule-scoped store
consumption. The dispatcher must `start_link` nothing.

Re-parenting alone is insufficient: if the dispatcher dies for any other reason its
supervisor still restarts it with `rules: []`. Loaded policies must live outside
dispatcher state in a supervised `PolicyStore` that the dispatcher rebuilds from on init.

---

## A-02 — Unbounded event recursion never terminates

**Filed:** 2026-08-06 · **Severity:** CRITICAL · **[REPRODUCED]**

### Symptom

`:emit` with a label (`dispatcher.ex:428-432, 504`), `:nextevent` (`:557`), and
`:nextrule` (`:562`) all recurse into `dispatch_to_rules/3` with no depth counter, no
visited set, and no cycle detection.

```text
rule a { when A { log "a" nextevent B } }
rule b { when B { log "b" nextevent A } }
```

No termination within 4s. The calling process dies at the 5s `GenServer.call` timeout;
the dispatcher keeps recursing at 100% CPU, growing its stack, until the VM dies. Every
other event in the system blocks behind it, because the dispatcher is the sole
serialization point for all dispatch.

### Why it happens

`while` loops *are* bounded — `@while_limit 10_000` at `lib/anemos/compiler.ex:632`. The
bound was applied to iteration and not to recursion. Per NASA Power of 10 rule 2, which
this project's doctrine adopts, every loop needs a fixed upper bound, and event
recursion is a loop.

### What should change

Thread a depth counter through `dispatch_to_rules/3` with a ceiling of 10,000 matching
`@while_limit`. Return a structured error through `Anemos.Runtime.Errors` on breach.
Apply to all three recursion paths. Do not crash and do not silently truncate.

---

## A-03 — Process dictionary leaks operations between unrelated rules

**Filed:** 2026-08-06 · **Severity:** CRITICAL · **[REPRODUCED]**

### Symptom

The compiler implements `return`/`done`/`nextevent`/`nextrule` as `throw`, using
`Process.put(:anemos_accumulated_ops, ...)` to carry the in-flight accumulator past the
throw (`lib/anemos/compiler.ex:520-534, 642-690`).

`eval_body/3` restores the previous value **only on the normal exit path**
(`compiler.ex:536-538`). `build_handler/1` catches the throw (`compiler.ex:494-502`) and
never restores the key.

```text
rule a (return):          {:ok, [%{type: :log, value: "a1"}], %{}}
process dict after throw: [%{type: :log, value: "a1"}]
rule c after leak:        {:ok, [%{type: :log, value: "a1"}, %{type: :log, value: "c1"}], %{}}
```

`rule c` emitted `rule a`'s operation. In production every rule runs in the one
long-lived dispatcher process, so the leak is permanent and cross-policy.

Here the leaked op was a `log`. The same path carries `:command` ops, so a device or
file command from one rule can be re-executed by an unrelated rule that happens to use
`return` — silently, non-deterministically (it depends on rule ordering within the
index), and invisibly in the result list, which simply shows one extra operation.

### Why it happens

A `throw` unwinding an `Enum.reduce` discards the in-flight accumulator, and the process
dictionary was used to carry it out. The mechanism is correct on the normal path and
unbalanced on the throw path — which is precisely the path it exists to serve.

### What should change

Thread the accumulator through the throw payload. `throw({:anemos_return, ops, bindings})`
already carries ops, so the dictionary is redundant on that path; the reduce accumulator
just needs to be reachable, which `reduce_while` provides. Minimum viable fix if the
rewrite is deferred: wrap `build_handler`'s body in `try/after` restoring the key.

---

## A-04 — Every `condition` fires unconditionally

**Filed:** 2026-08-06 · **Severity:** CRITICAL

### Symptom

`lib/anemos/compiler.ex:204`:

```elixir
evaluator = fn _event_name, _context -> true end
```

The trigger expression is parsed and never compiled into the evaluator. Every condition
transitions `false → true` on the first subscribed event it sees, regardless of its
stated trigger.

Separately, condition bodies compile to a `side_effect_handler` whose returned operations
are then discarded by the server (`lib/anemos/runtime/condition_server.ex:75`) — only the
synthetic `CONDITION_<name>` event escapes.

### Why it happens

Unknown; the parser produces the trigger expression and the compiler ignores it. This
looks like an unfinished implementation rather than a deliberate simplification, but no
comment or spec reference says so.

### What should change

Compile the trigger expression into the evaluator. Decide whether condition-body
operations are meant to execute — if they are, route them; if they are not, do not
compile them.

Conditions are the construct a user reaches for to express "only when X". They currently
express "whenever anything happens", which makes the construct actively misleading.

---

## A-05 — `signed_by` is parsed and never verified

**Filed:** 2026-08-06 · **Severity:** HIGH

### Symptom

`lib/anemos/parser.ex:163` stores the signer in rule metadata:

```elixir
defp parse_rule_metadata([{:keyword, _, :signed_by}, {:atom, _, signer} | rest], acc) do
  parse_rule_metadata(rest, Map.put(acc, :signed_by, signer))
end
```

The value is never read again. Grep confirms zero verification code anywhere in `lib/`:
no crypto call, no key lookup, no comparison. Likewise `Anemos.Envelope`
(`lib/anemos/envelope.ex:18`) declares a `:signature` field that no code path populates.

### Why it happens

`docs/design-notes/future-features.md:141` places DID signing in the future section, and
`README.md:458` describes the envelope field as "reserved". The keyword shipped ahead of
the mechanism.

### What should change

A rule file reading `signed_by :operator.did` looks authenticated to every human and
every tool that inspects it, and is accepted identically to an unsigned one. It
manufactures false provenance — worse than having no signing at all.

Under the multi-tenant decision this must be **implemented**: verify the signature
before `load/2` installs the rule, and reject on failure.

---

## A-06 — Context isolation fails open, two ways

**Filed:** 2026-08-06 · **Severity:** HIGH · **[REPRODUCED]** · found independently by four analysts

### Symptom

`lib/anemos/runtime/dispatcher.ex:443-450`:

```elixir
defp context_matches?(_rule, nil), do: true

defp context_matches?(rule, event_context) do
  case get_in(rule, [Access.key(:meta), :context_path]) do
    nil -> true
    rule_context -> String.starts_with?(event_context, rule_context)
  end
end
```

1. An event with no `:context_path` matches every rule regardless of scope.
   `Anemos.Runtime.dispatch(:anemos, "EVENT")` omits context by default
   (`runtime.ex:132`), so the simplest and most likely call in any host application
   silently disables context isolation entirely. The CLI never sets a context path at all.
2. The prefix match has no segment boundary. Reproduced: a rule scoped to `garage` fires
   on an event with context `garageband.amp`.

### What should change

Default-deny when a rule declares a context and the event supplies none. Compare path
segments, not raw string prefixes:
`event_context == rule_context or String.starts_with?(event_context, rule_context <> ".")`.

Context is documented as an exclusionary boundary. Under the multi-tenant decision it is
a security boundary, so it must fail closed.

---

## A-07 — Capability context scoping is decorative

**Filed:** 2026-08-06 · **Severity:** HIGH

### Symptom

`Anemos.Runtime.CapabilityServer` takes a `:context` at init and stores it
(`lib/anemos/runtime/capability_server.ex:124`) — and never reads it again.
`handle_call({:execute, context}, ...)` at line 131 invokes the handler unconditionally.
`Anemos.Runtime.Demand.evaluate/3` (`lib/anemos/runtime/demand.ex:44-53`) looks the
capability up by name in a flat map and executes it, with no comparison against the
demanding rule's context.

The `context infra.networking` line in the shipped example (`priv/examples/ddns.rule:2-9`)
constrains nothing. A rule declared in any context — or in none — can
`demand katachora-ddns-key` and receive the unlocked secret.

Combined with A-06, there is no working scope isolation anywhere in the runtime.

### What should change

Pass the demanding rule's context into `CapabilityServer.execute/2` and reject on
mismatch inside the server, where the capability's own context lives.

---

## A-08 — Unbounded atom creation can kill the node

**Filed:** 2026-08-06 · **Severity:** HIGH

### Symptom

Every distinct identifier in a policy source becomes a permanent BEAM atom. Atoms are
never garbage collected, and exceeding the table limit (default 1,048,576) is an
unrecoverable `system_limit` abort of the entire node — not a supervised process crash.

Call sites, all reached from untrusted source text:

```text
lib/anemos/lexer.ex:504   String.to_atom(value) on EVERY identifier token
lib/anemos/lexer.ex:432   duration units
lib/anemos/lexer.ex:472   DAY_* literals
lib/anemos/lexer.ex:499   demand flags
lib/anemos/parser.ex:484  recurrence names
lib/anemos/parser.ex:1529 expect atom lists
```

`lexer.ex:504` is the serious one: it converts to an atom first and checks keyword
membership second, so every non-keyword identifier is interned as a side effect of the
keyword test.

### Why it matters here specifically

`load/2` is designed to be called repeatedly at runtime with arbitrary policy source. A
single policy containing ~1M unique identifiers takes the node down permanently. Note the
asymmetry: a policy parse failure is recoverable; atom exhaustion is not.

### What should change

At `lexer.ex:504`, match against a compile-time `MapSet` of keyword strings and never
convert unmatched identifiers. Use `String.to_existing_atom/1` with a rescue at the other
five sites, where the accepted values are closed sets.

---

## A-09 — Default connector logs secrets in plaintext

**Filed:** 2026-08-06 · **Severity:** HIGH

### Symptom

`lib/anemos/channel/logger.ex:52`:

```elixir
Logger.info("[anemos]#{type} emit to #{channel}#{label}: #{inspect(envelope.payload)}")
```

This is the **default** connector — `lib/anemos/channel.ex:26-28` states it is used when
nothing is registered, "so emits are never silent". The `:log` operation does the same at
`dispatcher.ex:499-503`.

The shipped example `priv/examples/ddns.rule:5-8` demonstrates obtaining a secret by
emitting it:

```text
on demand {
  emit [SECRET::unlock(agent.did_...operator.security:did_key_67890)]
    as :katachora.ddns.key
}
```

With the default connector the unlocked secret is `inspect`ed into the application log at
`:info`, and from there into whatever ships logs off the host. No redaction exists
anywhere: no `Inspect` protocol override, no `:redact` marking, no sensitive-value
wrapper type.

### What should change

A wrapper struct for secret-bearing values with a custom `Inspect` implementation
rendering `#Secret<redacted>`, returned by `SECRET`-class verbs. `Channel.Logger` should
log payload type and size, never contents. See also A-21, which leaks the same material
through error messages.

---

## A-10 — `ModuleRegistry` verb routing can be hijacked

**Filed:** 2026-08-06 · **Severity:** HIGH

### Symptom

`lib/anemos/runtime/module_registry.ex:27-29`:

```elixir
def register(registry, name, module) do
  Agent.update(registry, &Map.put(&1, name, module))
end
```

Last write wins, with no authorization, no immutability, and no duplicate detection. Any
process that can name the registry — `:"#{name}.registry"`, a public documented
convention at `runtime.ex:214` — can rebind `"SECRET"` or `"INFRA"` to an
attacker-chosen module. Every subsequent `[SECRET::unlock ...]` dispatches to it with
arguments intact, and the policy behaves normally from the outside.

`SubscribableRegistry` (`subscribable_registry.ex:58`) and `ContextStore`
(`context_store.ex:170`) have the same shape. `ContextStore` holds the values that
`?variable` dereferences resolve to, so writing it steers rule logic.

### What should change

Make module registration write-once — reject rebinding a live name, or require an
explicit `replace: true`. At minimum, log every registration and re-registration at
`:warning`.

---

## A-11 — No input validation between DSL and host verbs

**Filed:** 2026-08-06 · **Severity:** HIGH

### Symptom

`lib/anemos/runtime/dispatcher.ex:490-497` passes `args` verbatim to
`mod.handle_verb/3`. Args arrive from policy literals and from event payloads. There is
no argument schema, no type check, no length bound, no allow-list, no escaping, and no
taint tracking anywhere in the pipeline.

The `Anemos.Module` macro (`lib/anemos/module.ex:56-67`) makes it a one-liner to bind a
DSL verb to a powerful host function, and its own moduledoc uses secret unlocking as the
worked example.

Concretely: `Comn.Repo.File.Local` calls `File.open/2`, `File.stream!/1` and `File.write`
on caller-supplied paths with no normalization and no root confinement. Wire that to a
real `FILE` verb — which `lib/anemos/runtime/modules/file.ex` exists as a placeholder for
— and `[FILE::read "../../etc/shadow"]` is a working path traversal on day one.

The `context` map handed to every verb also carries the live `:data_store` pid
(`dispatcher.ex:408`) — a process handle exposed to every third-party verb.

### What should change

Add an optional `arg_schema/1` callback to `Anemos.Runtime.Module`, enforced by the
dispatcher before `handle_verb/3`. Validate in the framework, not in each host module.
Confine every path-taking verb to a configured root via `Path.expand/2` plus a prefix
assertion. Stop passing the `:data_store` pid to verb handlers.

---

## A-12 — `load/2` has no trust boundary

**Filed:** 2026-08-06 · **Severity:** HIGH

### Symptom

`Anemos.Runtime.load/2` (`lib/anemos/runtime.ex:56`) accepts an arbitrary source string at
runtime, parses it, compiles it to closures, and installs it into the live dispatcher.
No caller authentication, no authorization, no signature verification, no sandbox, no
resource ceiling.

It is additionally exposed through the generic `Comn` action surface —
`act(%{action: :load, name: name, source: source})` at `lib/anemos/runtime.ex:208` — so
anything that can reach the Comn action dispatcher can load policy.

Whoever controls a `.rule` string controls every module verb registered in the runtime,
including, per the shipped example, the one that unlocks credentials.

### What should change

Under the multi-tenant decision, `load/2` is the trust boundary. Gate it behind an
explicit privileged path with a verified signature (A-05). Remove `:load` from the
`Comn.act/1` surface.

**Mitigating factor, worth preserving:** the compiler performs no code generation. There
is no `Code.eval*`, no `Code.compile*`, no `Module.create`, no `EEx`, no `apply/3`
anywhere in `lib/`. This caps the blast radius of malicious policy text at the verbs the
host has registered, and it is the single best security property in the codebase. Note
that `CLAUDE.md` describes the compiler as producing "executable rule modules", which
undersells this — the code is safer than the documentation implies.

---

## A-13 — Demand fails open on unknown capabilities

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`lib/anemos/runtime/demand.ex:55-63` treats a capability that does not exist identically
to one that merely failed. Under `:optional` or `:sufficient` the stack continues and, if
nothing else fails, returns `{:ok, results}` — the gate passes having authorized nothing.
A demand stack composed entirely of `:optional` flags is a no-op that reads like an
authorization check, and a typo in a capability name silently disables the gate.

### Why it happens

PAM's flag semantics govern how *failure* is handled. "The named capability is not
loaded" is a configuration error, not a failure.

### What should change

`handle_missing/6` returns the error unconditionally, independent of flag. Route it
through `Anemos.Runtime.Errors` — it is currently a bare tuple that bypasses the registry
the rest of the runtime uses (see A-22).

---

## A-14 — Unbounded timers permit resource exhaustion

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`lib/anemos/runtime/scheduler.ex:83-86` installs `:timer.send_interval(ms, ...)` where
`ms` comes from `Anemos.Runtime.Duration.to_ms/1` (`duration.ex:21-29`), which applies no
floor, no ceiling, and no sanity check. A policy specifying a 1ms interval installs a
1000 Hz loop of synchronous calls into the single dispatcher. A handful saturate the
runtime and starve every other rule. There is no limit on the number of schedules a
policy may install.

`to_ms/1` also has no catch-all clause: an unrecognized unit raises `FunctionClauseError`
inside `Scheduler.init/1`, taking the scheduler down.

### What should change

Clamp intervals to a configured minimum, cap total schedules per runtime, and add a
`to_ms/1` fallback returning an error tuple.

---

## A-15 — Duplicate `load/2` doubles execution; no unload

**Filed:** 2026-08-06 · **Severity:** MEDIUM · **[REPRODUCED]**

### Symptom

`handle_call({:load, ...})` does `state.rules ++ compiled.rules`
(`lib/anemos/runtime/dispatcher.ex:251`) with no dedup on rule name and no replace
semantics. Reproduced: loading the same policy twice makes every rule in it fire twice.

Re-loading a policy that redefines a condition also **orphans** the previous
`ConditionServer` — `Map.merge` at `dispatcher.ex:252` replaces the map entry while the
process stays alive, stays linked, and becomes unreachable.

Accumulation is documented as intended (`runtime.ex:47-53`), but there is no `unload`, no
`replace`, no warning on a duplicate rule name, and no way to inspect what is loaded. Any
hot-reload story built on this API double-fires every rule.

### What should change

Replace-or-reject semantics on duplicate rule names, plus an unload/reload path. Stop
orphaning condition servers. The same applies to `Scheduler.schedule/2` (A-19).

---

## A-16 — `nextrule`/`nextevent` discard state

**Filed:** 2026-08-06 · **Severity:** MEDIUM · **[REPRODUCED]**

### Symptom

`execute_op` for `:nextevent` (`dispatcher.ex:557-560`) binds `{results, _state}` and
discards the state. `:nextrule` (`:562-574`) discards `_new_persistent`.

```text
nextrule results:              [ok: %{type: :log, value: 1}]
rule_bindings after nextrule:  %{"caller" => %{}}
```

The body ran, but `set n = 1` evaporated — there is no `"counter"` key at all. A rule
maintaining a counter across invocations produces correct output when called directly and
silently resets every time it is reached via `nextrule`.

`nextrule` additionally passes a synthetic event name `"nextrule:#{target}"` that no
subscription can match, and drops the `args` the compiler resolved
(`compiler.ex:682-691`) — `nextrule foo { a: 1 }` parses, compiles, and the arguments go
nowhere.

### What should change

Thread state through nested dispatch. Deliver `nextrule` args.

---

## A-17 — Sibling `when` block destroys armed dwell state

**Filed:** 2026-08-06 · **Severity:** MEDIUM · **[REPRODUCED]**

### Symptom

`rule_bindings` is keyed by rule name only, but a rule with multiple `when` blocks
compiles to multiple `CompiledRule` structs sharing that name
(`lib/anemos/compiler.ex:314-327`). `dispatch_immediate` overwrites
`rule_bindings[rule.name]` with the handler's `{:set, _}`-filtered output
(`compiler.ex:508-513`), wiping any `{:dwell, _}` entry.

```text
rule r { when OTHER {...} when SIGNAL for 200ms {...} }
rule_bindings after sibling fire: %{"r" => %{}}
```

The pending `Process.send_after` still fires 200ms later, finds no entry, matches the
`_ ->` clause and is dropped silently as "stale" (`dispatcher.ex:328-331`). The dwell body
never runs and nothing reports it.

Same root cause: `handle_info({:dwell_fire, ...})` locates the rule with `Enum.find` on
name and subscription (`dispatcher.ex:298`), so two `when` blocks in one rule watching the
same event are silently collapsed to one.

### Why it happens

Timer state, `until` guard flags, and user `set` bindings share one flat map keyed by rule
name — three different lifetimes in one namespace. There is an explicit 20-line workaround
at `dispatcher.ex:307-321` covering the case where the dwell body itself fires; it does
not cover the sibling case.

### What should change

Separate dwell state from `set` bindings. Key dwell state by `(rule, when-block)` rather
than by rule name.

---

## A-18 — `Anemos.run/2` leaks 4 processes per call

**Filed:** 2026-08-06 · **Severity:** MEDIUM · **[REPRODUCED]**

### Symptom

`Anemos.run/2` stops the dispatcher with `GenServer.stop/1`, which exits `:normal`.
Non-trapping linked processes ignore that signal, so `TripleStore`, `DataStore`,
`SubscribableRegistry`, and every `ConditionServer`/`CapabilityServer` survive
permanently.

```text
process count before/after 20 runs: {156, 236}
```

80 leaked over 20 calls, exactly 4 per call, never reclaimed. Harmless for the CLI, where
the VM exits; unbounded for any host calling `Anemos.run/2` in a loop.

### What should change

Likely falls out of the A-01 supervision rework. Verify with a test that counts processes
across N calls.

---

## A-19 — Same-time `at` blocks collide and leak timers

**Filed:** 2026-08-06 · **Severity:** MEDIUM · **[REPRODUCED]**

### Symptom

`at` blocks compile to a synthetic event name derived purely from the time spec
(`lib/anemos/compiler.ex:416-442`) — it carries no rule identity. Two rules with
`at 08:00`:

```text
schedule event names: ["AT_08_00", "AT_08_00"]
rules: [{"at_AT_08_00", ["AT_08_00"]}, {"at_AT_08_00", ["AT_08_00"]}]
```

1. `Map.put(timers, sched.event_name, ...)` overwrites the first entry. The first timer is
   never cancelled and keeps firing — a leaked timer producing spurious dispatches.
2. Both rules share the name `at_AT_08_00`, so they share one `rule_bindings` entry —
   the A-17 collision, now across unrelated rules in unrelated policy files.

There is also no unschedule API at all: `state.schedules` grows on every `load/2`, and
interval timers are never cancelled.

### What should change

Derive schedule event names from rule identity as well as time spec. Add timer
cancellation and an unschedule path.

---

## A-20 — Schedules that can never fire report `:ok`

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`start_timer/1` returns `nil` for a past-dated `{:date, ...}`
(`lib/anemos/runtime/scheduler.ex:104-107`) and for an unresolvable `{:nld, text}`
(`:114-120`). The `nil` is stored in the timers map as if it were a timer reference and
`schedule/2` still returns `:ok`. A schedule that will never fire is indistinguishable
from one that will.

Related and unfixed here: all time arithmetic uses `NaiveDateTime.local_now/0`, so DST
transitions and clock changes are unhandled — a recurring 02:30 job silently double-fires
or skips on transition days. Recurrence is implemented only for `{:time, {h, m}}`
(`scheduler.ex:122-125`); recurring day-of-week and date specs fire once and stop.

---

## A-21 — Internal error detail returned to callers

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`lib/anemos/runtime/dispatcher.ex:467-479` rescues eight exception types and returns
`Exception.message(e)` verbatim; `:409-411` wraps it as
`"Rule #{rule.name} raised: #{inspect(reason)}"`. These flow out through
`Anemos.Runtime.dispatch/3` to the caller and, via the Mix task
(`lib/mix/tasks/anemos.run.ex:54`), onto the console.

`KeyError` and `BadMapError` messages embed the full offending term. In a runtime whose
stated purpose is handling secrets, a `KeyError` on a map containing an unlocked
credential prints that credential into the error result. See also A-09.

### What should change

Log detailed errors internally against the correlation id the dispatcher already
generates (`dispatcher.ex:354`), and return only that id plus a stable error code.

---

## A-22 — Three incompatible error representations

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

| Style | Example |
| --- | --- |
| Structured `Comn` error | `Comn.Errors.Registry.error!("anemos.runtime/handler_crash", ...)` (`dispatcher.ex:437`) |
| Ad-hoc tuple | `{:error, {:handler_crash, rule.name, reason}}` (`dispatcher.ex:571`) |
| Bare string | `{:error, "Lexer error on line #{line}: ..."}` (`parser.ex:62`) |

The same logical failure — a rule handler crashing — produces a structured error on the
`dispatch_immediate` path and a raw 3-tuple on the `nextrule` path. Callers cannot
pattern-match uniformly on anything.

Related fail-open and fail-silent defects in the same area:

- `Anemos.Runtime.load/2` (`runtime.ex:56-65`) discards the return values of
  `Dispatcher.load/2` and `Scheduler.schedule/2` and returns a hardcoded `:ok`. Only
  parse/compile failures reach the caller.
- `dispatch/3` (`runtime.ex:134-144`) always returns `{:ok, results}` even when every
  element is an error.
- Channel publish results are discarded (`dispatcher.ex:524`) — a connector returning
  `{:error, reason}` is indistinguishable from success and the emit still reports `{:ok, op}`.
- `safe_handle/4`'s bare `catch kind, reason` (`dispatcher.ex:478-480`) catches `:exit` as
  well as `:throw`, converting a `GenServer.call` timeout from a downstream module verb
  into a hidden rule-level error. The `rescue` list above it is deliberately bounded; the
  `catch` below undoes that discipline.
- The `ErrorStruct` carries a `suggestion:` field that is `nil` in every error the system
  produces (see A-31).

---

## A-23 — `TripleStore` unbounded list, O(n) insert

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`lib/anemos/runtime/triple_store.ex` stores triples in a plain list, performs a full
`Enum.filter` on every query, and does an `if triple in triples` membership check before
prepending (`:41-46`). Insert is O(n), building n triples is O(n²), there is no retract
operation, no size limit, and no persistence. A rule asserting one triple per event
degrades continuously and then exhausts memory.

### What should change

`MapSet` (already used elsewhere in this codebase) fixes the constant factor. The
unboundedness needs a retention policy, which is a design decision.

---

## A-24 — `DataStore` scope discriminators inconsistent; cleanup unreachable

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

Entries are keyed `{name, scope_tag}` where scope is `:global` or
`{:local, discriminator}`. Two defects:

1. `member?/4` accepts a `:scope_hint` and the dispatcher passes the **rule name string**
   (`dispatcher.ex:409` → `compiler.ex:832`), but `get/2` hardcodes `self()`
   (`data_store.ex:104`). `get` can never reach a rule-scoped entry. Two lookup
   functions, two different scope models.
2. `maybe_monitor/2` only monitors when the discriminator is a pid
   (`data_store.ex:206-215`); the `{:local, name}` clause is an explicit no-op. Since the
   dispatcher always passes strings, the `:DOWN` cleanup handler (`:187-198`) is
   unreachable in practice, and every policy reload adds entries that are never removed.

The moduledoc says the scope is `{:local, pid}`; the live callers pass
`{:local, String.t()}`.

---

## A-25 — Unbound variables silently resolve to `nil`

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

```text
[let a = 42, read with @a]  => {:ok, [%{type: :log, value: 42}]}
[let a = 42, read with $a]  => {:ok, [%{type: :log, value: nil}]}
[log @nosuchvar]            => {:ok, [%{type: :log, value: nil}]}
```

`Map.get/2` with no default (`lib/anemos/compiler.ex:739-750`). Wrong sigil, typo, or
genuinely absent context data all resolve to `nil`, log an empty line, and report success.
There is no distinction between "you meant a different sigil" and "the environment did not
supply this".

**A shipped example has this bug.** `priv/examples/normalize-pdfs.rule:9-12` binds
`let title = ...` (creating `@title`) and then compares `if $title ne $meta_title`. Both
are `nil`, `nil ne nil` is false, and the branch is dead. Nobody noticed because nothing
complained.

### What should change

Distinguish "not bound" from "bound to nil" in `resolve_expr` and surface the former as a
diagnostic. This is the defect most likely to cost a user hours, because the failure mode
for a typo is a successful run with wrong output.

---

## A-26 — Subscription failures logged and dropped

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`lib/anemos/runtime/dispatcher.ex:236-245` downgrades subscription failures to
`Logger.warning` and `load/2` still returns `:ok`. A data block whose feed fails to
connect silently becomes an empty `MapSet`, so every `memberof()` check against it quietly
returns `false`.

For an allow/deny-list — the documented use case — fail-open is the wrong default and the
caller is never told.

Related: the `{:ok, ref}` returned by `handler.subscribe/3` is matched and thrown away
(`dispatcher.ex:237`). `Anemos.Subscribable.unsubscribe/1` and `periodic?/0` are declared
and called from nowhere. Subscriptions are create-only — they cannot be cancelled, listed,
or restarted, and they outlive the data block they feed. The `periodic` half of the parsed
tuple is destructured and discarded, so polling is parsed but not implemented.

---

## A-27 — No CI, no linting, no static analysis

**Filed:** 2026-08-06 · **Severity:** LOW

128 commits, zero automated verification. No `.github/workflows`, no pipeline config of
any kind. No Credo, no Dialyzer, no Sobelow, no PLT.

Currently failing if anyone did run them:

```text
mix format --check-formatted   FAILS on lib/anemos/parser.ex
mix test --cover               FAILS: 73.53% against a 90.00% threshold
```

Coverage low points: `RuleSupervisor` 0%, `Mix.Tasks.Anemos.Run` 0%, `Scheduler` 20%,
`Anemos.Parser` 66%. The Scheduler is the module with the most branching and the least
verification.

Also: ~66 `@spec` across 609 function definitions, and the core value in the system —
`CompiledRule.handler` — is an untyped closure returning bare `map()` operations with no
`@type operation ::` union, so the compiler and dispatcher agree on the op vocabulary only
by hand and by moduledoc. The two dead `execute_op` clauses for `:register_data` and
`:register_query` (`dispatcher.ex:576-598`, unreachable since the compiler moved inline
data registration to load time) are what that looks like when the hand-sync slips.

Tests use 20 `Process.sleep` calls as wall-clock timing assertions; the flake tax is
already visible in the history (`9116ec3 chore: ... widen dwell-test timing window`). Test
logging is not silenced, so a run prints hundreds of `[info]` lines that drown failures.

---

## A-28 — `comn` path dependency makes the repo unbuildable

**Filed:** 2026-08-06 · **Severity:** LOW (but blocks every other contributor)

`mix.exs:39` declares `{:comn, path: "../comn"}` — an unpublished sibling checkout with no
git URL, no version, and no fallback. Path dependencies do not appear in `mix.lock`, so the
single most important dependency has no recorded version.

`comn` is not incidental: it supplies `Comn.Errors.Registry`, `Comn.Contexts`,
`Comn.Discovery`, `Comn.EventBus`, and the `@behaviour Comn` implemented by five modules.
Anemos cannot compile without it and cannot tell you which version it needs. Publishing to
Hex is impossible in this state, and the README has no installation section explaining that
a sibling checkout is required.

Related: `mix.lock` is tracked in git **and** listed in `.gitignore` — the two declarations
contradict each other.

---

## A-29 — `TODO.md` contradicts the README and the code

**Filed:** 2026-08-06 · **Severity:** LOW

`TODO.md` lists under "Not implemented (15%)": loops, flow control, guards, pipelines. All
four are implemented, tested (`loop_test.exs`, `flow_control_test.exs`, `guard_test.exs`,
`pipeline_test.exs`), and marked done in the git history. It also claims "All three example
files parse and run" — see A-30.

A newcomer reading `TODO.md` will substantially **underestimate** the system. It also mixes
three checkbox conventions and carries heavy trailing whitespace.

An untracked file at the repo root, `● Here's where we stand against the spec.md`, is a
third differently-stale copy of the same status information with a U+25CF in the filename.

Ten further doc/code contradictions are tabulated in
`.legacy/docs/CODEBASE_ANALYSIS.md`, Appendix A.

---

## A-30 — Two of three shipped examples do not work

**Filed:** 2026-08-06 · **Severity:** LOW

| Example | Result |
| --- | --- |
| `garage-lights.rule` | Works |
| `normalize-pdfs.rule` | `No rules matched event FILE_CREATED.` |
| `ddns.rule` | 2 of 4 operations fail |

`normalize-pdfs.rule` fails twice over: its outer guard compares against the `FILE` stub's
echo map, which never equals `"pdf"`, and the inner body is dead per A-25. `ddns.rule`
references an `INFRA` module that is not among the two registered defaults
(`lib/anemos.ex:14-17`).

`ddns.rule` also demonstrates an interpolation gap: `as ddns.update.:{?fqdn}` renders
literally. The `:{...}` form appears in the README, both examples, and the parser, and
produces no substitution and no error.

Related CLI defects: `{:ok, []}` is reported as "No rules matched", which is factually
wrong — it means zero *operations*, and collapses three distinct states into one
misleading message. The CLI exits 0 even when the result list contains hard failures, so it
cannot be used in a script or CI gate.

---

## A-31 — Parser diagnostics contradict stated ergonomics principle

**Filed:** 2026-08-06 · **Severity:** LOW

`docs/design-notes/language-ergonomics.md` principle 6 states error messages should suggest
corrections and users should be able to safely guess syntax. Measured against 14 malformed
inputs:

- Internal token names leak to end users: `lbrace`, `rbrace`, `lbracket`, `keyword`,
  `operator`. A policy author has never seen these terms.
- The offending token's *value* is never shown.
- No column, contradicting `CLAUDE.md`'s stated convention. The lexer computes a column and
  the parser discards it at `lib/anemos/parser.ex:61`.
- No source excerpt or caret.
- The most common beginner error — an unbalanced brace — produces
  `Unexpected end of input, expected statement`, with no line number at all.
- No suggestions, ever. The `ErrorStruct.suggestion` field is `nil` in every error the
  system produces, even where the full registry is in hand at the moment of failure.

There is also essentially no compile-time checking: the entire compiler has one diagnostic
(`compiler.ex:449`). Unknown modules, verbs, capabilities, `nextrule` targets, undefined
variables, sigil/keyword mismatches, and duplicate declaration names are all unchecked. A
policy file can be entirely wrong and compile cleanly.

Error strings are built inline at ~60 sites in the parser alone, so there is no central
place to improve message quality. One `Anemos.Diagnostics` module formatting
`{code, line, token, source_line, suggestion}` would fix all of it at once.

---

## A-32 — Repository hygiene

**Filed:** 2026-08-06 · **Severity:** LOW

- `erl_crash.dump` — 5.9 MB, dated 2026-04-16, in the working tree. Correctly gitignored
  and not tracked, so it will not reach the remote, but heap dumps routinely contain
  credentials. A string scan found only test fixture material, so no live secret is known
  to be exposed. Delete it.
- Three `.tcl` design sketches are tracked **twice** — at the repo root and under
  `docs/design-notes/sketches/`. The root copy of `stop-data-extraction-policy.tcl` is
  diverging. Two are marked `0755` despite having no shebang.
- `● Here's where we stand against the spec.md` — untracked, leading U+25CF, a pasted
  terminal transcript. Delete.
- `.gitignore` does not cover `.elixir_ls/` or `.codegraph/`.
- ExDoc publishes `RuleSupervisor` and `DataModelRegistry` as live API pages,
  indistinguishable from working modules (L-01, L-02).

---

## A-33 — `Anemos.Module` documents two functions that do not exist

**Filed:** 2026-08-06 · **Severity:** MEDIUM · found while verifying the `comn` findings

### Symptom

`lib/anemos/module.ex:14-15` presents this as the worked example of binding a DSL verb to
a host function:

```elixir
verb :unlock, &Comn.Secret.unlock/2
verb :rotate, &Comn.Secret.rotate/1
```

Neither function exists. `Comn.Secret` is a **protocol** (`comn/lib/comn/secret.ex:1`)
exposing exactly two functions, `to_blob/1` and `from_blob/1`. A user who copies the
moduledoc example gets an undefined-function error at the `&` capture.

The lock/unlock operations live on `Comn.Secrets` (plural) as behaviour callbacks
`lock/2` and `unlock/2`. There is no `rotate/1` anywhere in `comn` — see C-3 in
`.legacy/docs/comn-findings.md`, which confirms a repository-wide grep for `rotate`
returns nothing and that the `Comn.Secrets` behaviour declares only `lock/2`, `unlock/2`,
`wrap/2`, `unwrap/2`.

### Why it happens

The example was written against an intended API rather than the shipped one, and nothing
compiles or tests moduledoc examples that appear inside a `use` macro's documentation —
these are not doctests.

### Why it matters beyond a typo

This is the example the 2026-08-06 audit cited as evidence for A-11 (no input validation
between DSL and host verbs) — "the macro makes it a one-liner to bind a DSL verb to a
powerful host function, and its own moduledoc uses secret unlocking as the worked
example". The security argument stands on the macro's shape, not on this example, so A-11
is unaffected. But the example itself is not merely dangerous, it is non-functional, and
it is the first thing a module author copies.

### What should change

Correct the example to the real API, or mark it explicitly as illustrative pseudo-code.
Prefer the former. Consider whether `use Anemos.Module` examples can be made into
doctests so they cannot rot again.

---

## A-34 — Format `data` blocks are silently discarded

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`data foo { edn { ... } }` parses, compiles, and vanishes. `memberof(foo)` then returns
`false` against a dataset the policy author believes they declared, with nothing in the
log.

### Why it happens

`compile_data/1` (`lib/anemos/compiler.ex:246`) handles `{:format_block, keyword, raw}`
by building a `CompiledData` with `format:` and `raw:` populated and `dataset: nil`. The
dispatcher (`lib/anemos/runtime/dispatcher.ex:218-222`) registers a block only
`if data.dataset`, then falls through to a `data.dynamic` check. A format block satisfies
neither branch and is dropped.

Contrast the dynamic path, which at least warns on an unregistered protocol
(`dispatcher.ex:244`). The format path has no equivalent.

### Why it matters beyond tidiness

A policy written to deny on membership will silently **permit** instead. This is the same
fail-open shape as A-26, reached by a different route.

### What should change

Full repair is the data-format feature itself (see L-02). Minimum repair independent of
that: warn when `data.dataset == nil and data.dynamic == nil` rather than dropping
silently.

---

## A-35 — `compile_query/1` is an unmarked stub; `query_blocks` never read

**Filed:** 2026-08-06 · **Severity:** MEDIUM

### Symptom

`compile_query/1` (`lib/anemos/compiler.ex:268-281`) builds a `handler` closure that
returns its own inputs — `%{engine:, body:, bindings:, context:}`. It executes nothing.

Nothing anywhere reads `CompilationResult.query_blocks` (`lib/anemos/compiler.ex:65`).
`Dispatcher.handle_call({:load, compiled}, ...)` iterates `compiled.data_blocks`
(`dispatcher.ex:218`) and never touches `compiled.query_blocks`.

A query block therefore compiles "successfully" and can never run. The existing test
(`test/anemos/query_block_test.exs`, added in `b7d1494`) asserts on parse and compile
output only, so the suite is green and the feature does not exist.

The design spec additionally requires a compile-time error on an unregistered engine
keyword (`docs/superpowers/specs/2026-04-15-data-query-blocks-design.md:204`). Instead
every keyword is accepted.

### What should change

Either implement the query path per the spec, or mark the construct explicitly
unimplemented so it fails loudly at compile time rather than silently at runtime. Do not
leave a construct that reports success and does nothing.

---

## A-36 — Spec/test drift on transducer naming

**Filed:** 2026-08-06 · **Severity:** LOW

`test/anemos/parser_test.exs:616` asserts a transducer named `"resource.transducer.edn"`,
while the design spec and its implementation plan both use the hyphenated
`"resource.transducer.edn-to-kb"`
(`docs/superpowers/plans/2026-04-15-data-query-blocks.md:467`).

Cosmetic in isolation, but it means nothing tests whether a hyphen survives inside a
dotted identifier — and if it does not, the spec's own worked example fails to parse.
Worth one test.

---

## A-37 — `compiler.ex:453` type confusion latent in dwell duration

**Filed:** 2026-08-06 · **Severity:** LOW (latent — not currently reachable)

### Symptom

`duration_to_dwell_ms/1` (`lib/anemos/compiler.ex:453`) calls
`Anemos.Runtime.Duration.to_ms/1`. As of the A-14 fix, `to_ms/1` no longer raises on an
unknown unit — it returns `{:error, {:unknown_duration_unit, unit}}`. The compiler would
store that error tuple as if it were a dwell duration in milliseconds.

### Why it is not currently a live bug

`lib/anemos/lexer.ex:24` constrains duration units to the nine supported values, so an
unknown unit cannot reach the compiler through the parser. This is defense-in-depth
against a future lexer or compiler change, not a reachable defect today.

### What should change

Switch `compiler.ex:453` to `Duration.to_ms!/1`, which was added for exactly this caller
and raises `ArgumentError` with a readable message. The distinction is deliberate:
`to_ms/1` must not raise because its other callers are long-lived processes where a
`FunctionClauseError` kills the scheduler rather than rejecting one schedule; the compiler
is a synchronous caller where raising is correct.

---

## A-38 — DST exposure is wider than `scheduler.ex`

**Filed:** 2026-08-06 · **Severity:** LOW

`NaiveDateTime.local_now/0` appears 8 times in `lib/anemos/runtime/scheduler.ex` and again
in `lib/anemos/runtime/nld.ex:49,104`. The A-20 entry attributes the DST and clock-change
exposure to the scheduler alone; natural-language date resolution has the same defect, so
a fix confined to `scheduler.ex` would leave `NLD_next_week` and friends still wrong
across a transition.

Related latent item: `handle_info({:fire_recurring, ...})` → `schedule_next_occurrence/1`
still returns a bare timer ref rather than `{:ok, ref}`. It is only reachable for
`{:time, {h, m}}`, which is always armable, so it is safe today — but it will need the
same treatment when recurrence widens beyond `{:time, ...}` (see A-20).

---

## A-39 — `nextrule` bypasses context filtering and the dwell state machine

**Filed:** 2026-08-06 · **Severity:** HIGH · found during the A-01 supervision work

### Symptom

`execute_op(%{type: :nextrule, ...})` in `lib/anemos/runtime/dispatcher.ex` filters
`state.rules` on `rule.name == target` and invokes the handler directly. It does not route
through `dispatch_to_rules/4`, so it skips both of the checks that function applies:

1. `context_matches?/2` — **a context-scoped rule invoked via `nextrule` fires outside its
   context.**
2. the `dwell_duration_ms` branch — a rule declared `when EV for 10min` fires immediately
   instead of arming its timer.

### Why this is a security finding, not a correctness one

Under the multi-tenant trust decision (2026-08-06), `context` is a security boundary. A-06
covers the two ways `context_matches?/2` itself fails open; this is a third route that
does not consult it at all. Any policy that can name a rule can invoke it outside its
declared context, which defeats the boundary even after A-06 is fixed.

A-06 and A-39 must be fixed together. Fixing `context_matches?/2` alone leaves this path
open.

### What should change

Route `nextrule` through `dispatch_to_rules/4` rather than reimplementing a subset of it.
That also fixes A-16's state loss on the same clause, and removes the synthetic
`"nextrule:#{target}"` event name that no subscription can match.

---

## A-40 — Persistent `set` bindings destroyed by a dispatcher restart

**Filed:** 2026-08-06 · **Severity:** MEDIUM · found during the A-01 supervision work

`lib/anemos/runtime/dispatcher.ex:128` initialises `rule_bindings: %{}`. `PolicyStore`
restores rules, conditions, capabilities and the channel connector on restart, but not
accumulated `$mutable` state.

A rule counting with `set $n` silently restarts from its initial value after any dispatcher
crash. No error, no log line.

This is the same class as A-01 — derived state with no durable backing — narrowed rather
than eliminated by the supervision work. The README documents `$` as surviving "across
firings" without stating that it does not survive a restart.

---

## A-41 — Armed dwell timers vanish on restart and never re-arm

**Filed:** 2026-08-06 · **Severity:** MEDIUM · found during the A-01 supervision work

Dwell timers are `Process.send_after(self(), {:dwell_fire, ...}, ms)` in the dispatcher
process (`dispatcher.ex:~660`). On restart every armed timer is gone.

Arming only happens on a subsequent matching event, so a `for <duration>` rule whose signal
is **already steady-true** can wait forever — the condition that would arm it has already
passed. `handle_info({:dwell_fire, ...})` drops non-matching fires silently by design, so
nothing surfaces.

Interacts with A-17 (sibling `when` blocks wiping dwell state) and A-42: all three are the
dwell state machine's state having no durable home.

---

## A-42 — Condition state resets to false on restart, causing a double-fire

**Filed:** 2026-08-06 · **Severity:** MEDIUM · **introduced by the A-01 fix, disclosed by its author**

`StoreSupervisor.put_condition/3` replaces rather than reuses a condition server, because
the `on_transition` callback closes over the dispatcher pid and a restarted dispatcher must
install callbacks pointing at itself. The consequence: a condition that was `true` reads
`false` after a dispatcher restart.

Since conditions broadcast on `false → true`, the next true evaluation **re-broadcasts**
`CONDITION_<name>`, firing rules that already ran. For a policy whose rules are not
idempotent, that is a duplicate side effect.

This is a real regression against the pre-fix behaviour in one narrow respect: before the
fix, a condition server crash killed the dispatcher outright, so there was no
"restarted dispatcher observing a stale condition" state to get wrong. The trade is
strongly favourable — total silent policy loss for a recoverable double-fire — but it is a
trade, and it is recorded here rather than buried.

Properly fixing it requires the deferred event-state model (level-vs-edge events, paired
event dwell cancellation), not a supervision change.

---

## A-43 — `ModuleRegistry` registrations have no durable backing

**Filed:** 2026-08-06 · **Severity:** MEDIUM · found during the A-01 supervision work

`lib/anemos/runtime/module_registry.ex` is an `Agent` with no durable backing. If it
crashes, every `Anemos.Runtime.register/3` is lost and `[MOD::verb]` returns
`anemos.runtime/unknown_module` forever.

Identical in shape to the `PolicyStore` defect that A-01 fixed, one supervisor child over.
`:rest_for_one` restarts the dispatcher behind it but cannot invent the registrations back
— only the host application knows them.

Note this compounds A-10: the registry is both hijackable and non-durable.

---

## A-44 — Parser accepts specs the runtime cannot dispatch

**Filed:** 2026-08-06 · **Severity:** MEDIUM · found during the A-08 work

### Symptom

`Anemos.Runtime.Scheduler.day_to_number/1` clauses only on `:monday`..`:sunday`. Before the
A-08 closed-set validation landed, both of these lexed, parsed, and compiled cleanly:

```text
at DAY_notaday { ... }
at 09:00 every notaday { ... }
```

They then raised `FunctionClauseError` inside the scheduler process when the timer fired —
far in time and place from the offending source line, and (before A-01) taking the
scheduler's whole timer set down with it.

### Status

Both instances are **incidentally fixed**: the A-08 work made `DAY_*` literals and
recurrence names closed-set lookups whose miss is a lexer or parse error. That was a side
effect of preventing atom interning, not a deliberate validation pass.

### Why it stays open

The *class* is unaudited. The parser accepts constructs the runtime cannot dispatch, and
the failure surfaces at fire time rather than at parse time. Two instances were found by
accident while fixing something else; nothing has systematically checked for others.

This is the same gap A-31 describes from the diagnostics side: there is no semantic
validation pass between compile and load. Unknown modules, verbs, capabilities, and
`nextrule` targets are all deferred to runtime in exactly this way.

### What should change

Audit every runtime function that pattern-matches on a value originating in policy text
and confirm the parser constrains it to the same set. The systematic fix is the semantic
validation pass in A-31.

---

## A-45 — Lexer post-processing errors report column 1

**Filed:** 2026-08-06 · **Severity:** LOW

`tokenize/1`'s `{:error, msg, line, col}` contract promises a real column, and `CLAUDE.md`
states "Parser errors include line/col position". But `build_tokens/3` carries no column
information, so post-processing errors — including the new closed-set `DAY_*` rejection —
hardcode column `1`. The line number is accurate.

Fixing this properly means threading column through token metadata, which is the same
change A-31 needs for its source-excerpt-and-caret work. Do them together.

---

## A-46 — The language has no boolean literals; `== true` is inverted from intent

**Filed:** 2026-08-06 · **Severity:** HIGH · **[REPRODUCED]**

### Symptom

`lib/anemos/lexer.ex` has no `true`/`false` token rule. `true` in policy source lexes as an
identifier, and the parser produces `%AST.Literal{type: :identifier, value: "true"}` — a
**string**.

Reproduced end to end against `if ?flag == true`:

```text
condition AST: %Anemos.AST.BinaryOp{
  op: :==,
  left:  %Anemos.AST.VarRef{sigil: "?", name: "flag"},
  right: %Anemos.AST.Literal{type: :identifier, value: "true"}   # <- a binary
}

?flag = true    (boolean) => {:ok, [], %{}}                      # guard does NOT fire
?flag = "true"  (string)  => {:ok, [%{type: :log, value: "fired"}], %{}}   # guard DOES fire
```

### Why this is worse than "always false"

The guard is **inverted from intent**, not merely dead. A host application that supplies a
genuine boolean — the natural thing to do, and what `Anemos.Event` payloads will carry from
any real event source — gets a guard that never fires. A host that happens to supply the
string `"true"` gets one that works. Neither behaviour is documented and nothing warns.

Every `== true`, `== false`, `!= true` and `unless ... == true` construct in every policy
is affected. This compounds A-25: the language's failure mode for this mistake is a
successful run with silently wrong output.

### Why it was not caught

Nothing in the test suite or the examples uses a boolean literal. It was found only because
a first draft of an unrelated condition test used `unless ?maintenance == true` and failed
for this reason.

### What should change

Add `true`/`false` as lexer tokens producing real boolean literals. Decide explicitly
whether `?var == "true"` should keep working for string-valued context data, or whether
that becomes a type error — and say so in the README's expression section.

---

## A-47 — Compound `AND` event triggers behave as `OR`

**Filed:** 2026-08-06 · **Severity:** MEDIUM

`event_to_subscriptions/1` (`lib/anemos/compiler.ex:520`) discards the `:and` / `:or`
operator from `{:compound, op, events}` and returns a flat subscription list. So:

```text
when (SENSOR_A AND SENSOR_B) { ... }
```

fires on **either** event alone. `AND` and `OR` compile identically.

The README documents compound events with both operators as a supported feature. `AND` is
the one a policy author would reach for to express "both of these have happened", and it
silently means "either".

### Status

Left unchanged deliberately during the A-04 work rather than guessed at. Correct `AND`
semantics require knowing whether the events must be simultaneous, or both-seen-within-a
-window, or both-currently-true — which is the deferred event-state model (level-vs-edge
events, paired-event dwell cancellation). Guessing here would bake in the wrong answer.

The A-04 evaluator work makes the gap explicit and cheap to close once that model lands.

---

## A-48 — `until` on a condition trigger cannot latch

**Filed:** 2026-08-06 · **Severity:** MEDIUM

A rule's `until` guard latches permanently via `persistent_bindings[{:until_tripped}]`. A
condition's evaluator is `(event_name, context) -> boolean` with nowhere to store that
latch (`lib/anemos/compiler.ex:255`).

It is currently compiled as "false while the guard holds", which **re-arms** if the guard
stops holding — whereas `until` on a rule is permanent. The same keyword means two
different things depending on which construct it appears in, and only one of them matches
the documented semantics.

Fixing it needs either state in `ConditionServer` or an evaluator signature change that
reaches `store_supervisor.ex`.

---

## A-49 — Multiple trigger blocks in one condition run each other's side effects

**Filed:** 2026-08-06 · **Severity:** MEDIUM

`compile_condition/1` concatenates every `when` and `at` body into a single `all_bodies`
list, so whichever trigger fires executes **all** of them.

Single-trigger conditions — the only form the spec grammar allows — are unaffected, which
is why this has never surfaced. But the parser accepts multiple trigger blocks, so it is
reachable from policy text. Same shape as A-17, where multiple `when` blocks in one rule
collide on shared state.

Fixing it means selecting bodies by triggering event, which pushes the side-effect handler
to 2-arity and out into `store_supervisor.ex`.

---

## A-50 — Condition-body operations are computed and dropped

**Filed:** 2026-08-06 · **Severity:** MEDIUM · partially fixed

### Symptom

`condition_server.ex:75` invoked the side-effect handler and discarded its return value:
`if state.side_effect_handler, do: state.side_effect_handler.()`. The operations a
condition body produces — including `emit` with a channel destination and
`[MODULE::verb]` commands — went nowhere. Only the synthetic `CONDITION_<name>` event
escaped.

### This is a defect, not a design choice — two independent sources

The language specification §3.2 states a satisfied condition "emits a `CONDITION_<name>`
event to the message bus", and its worked example at line 757 is:

```text
condition networkchanged {
  when (...) { emit [EVENT::ip.addr.changed to channel(...)] as :... }
}
```

That `emit` with a channel destination is the point of the block, not decoration. The
project's own condition-semantics design note agrees: "false→true transition: state
updates, `CONDITION_<name>` event fires, **side effects in the condition body execute**".

### Status

Partially fixed. The handler is now 1-arity and receives the triggering event context, so
`?var` in a condition body resolves instead of silently yielding `nil`. An optional
`:on_side_effects` callback — `(name, ops) -> any` — now receives the produced operations,
and the moduledoc states plainly that without it they are still dropped.

### What remains

`store_supervisor.ex:133-135` builds the `ConditionServer` child spec and must also pass
`on_side_effects:` — a closure handing `(name, ops)` to the same operation-execution path
the dispatcher uses for rule handler results. Until that is wired, a condition body's
`emit` and commands still go nowhere. One line in `store_supervisor.ex` plus an entry
point on the dispatcher.

---

## A-51 — `nextrule` args are dropped in the parser, not the compiler

**Filed:** 2026-08-06 · **Severity:** MEDIUM · corrects A-16's diagnosis

### Symptom

`lib/anemos/parser.ex:1098`:

```elixir
defp parse_nextrule([{:identifier, meta, target} | rest]) do
  {:ok, %AST.NextRule{target: target, args: nil, line: meta[:line]}, rest}
end
```

`args:` is hardcoded `nil`, and `%AST.BlockArgs{}` is **never constructed anywhere in the
parser** — `grep -c BlockArgs lib/anemos/parser.ex` returns 0.

### Correction to A-16

A-16 said "drops the `args` the compiler resolved... so they go nowhere". That points one
layer too low. The compiler resolves nothing because the parser never gives it anything.
`compiler.ex:683-691`, which resolves `%AST.BlockArgs{pairs: pairs}` into a map, is dead
code reachable only from a hand-built AST — which also explains the audit's Appendix B
observation that `AST.BlockArgs` is defined, documented, and never constructed.

`nextrule foo { a: 1 }` does not parse into args at all; the brace block is consumed
elsewhere.

### Status

The **delivery** half is now built: `dispatcher.ex`'s `nextrule_context/2` merges resolved
args into `:context_data` so a target rule reads them as `?a`. No compiler change is
needed — `compiler.ex:683-691` is already correct and starts working the moment the parser
feeds it. What remains is `parse_nextrule/1` constructing a `BlockArgs`.

---

## A-52 — `dispatcher.ex` still discloses payloads in three places

**Filed:** 2026-08-06 · **Severity:** MEDIUM · sibling of A-09

A-09 closed the disclosure in the default channel connector. Three sites in the dispatcher
have the same shape and were out of that agent's ownership:

1. **The `:log` operation** — `Logger.info("[anemos] #{value}")`. Arguably worse than A-09,
   because a policy author can put any expression in a `log` op. `Anemos.Secret` covers this
   for free when a value is wrapped — it interpolates as `[REDACTED]` — but an unwrapped
   secret goes straight to `:info`. One-line fix using `Anemos.Redact.summarize/1`.
2. **Handler crash reporting** — `"Rule #{rule.name} raised: #{inspect(reason)}"`. A crash
   reason routinely carries the arguments that caused it, which for `[SECRET::unlock ...]`
   is the credential. This is A-21 in concrete form.
3. **Subscription failure** — `"data block '#{name}' not subscribed: #{inspect(reason)}"`.
   Lower severity, same shape.

Sites 2 and 3 need a judgement call about how much of an error reason to keep for
debuggability; site 1 does not. `Anemos.Redact` and `Anemos.Secret` are both available with
no new dependency and no configuration.

---

## A-53 — CLI has no `--context`, so every scoped example prints "No rules matched"

**Filed:** 2026-08-06 · **Severity:** MEDIUM · **regression introduced by the A-06 fix**

### Symptom

```text
$ mix anemos.run priv/examples/garage-lights.rule --event SENSOR_MOTION_DETECTED
No rules matched event SENSOR_MOTION_DETECTED.
```

Same for `ddns.rule`. Both declare a `context`, the Mix task never supplies a context path,
and the now-fail-closed boundary correctly denies.

`garage-lights.rule` is the one example A-30 recorded as working, so this is a real
user-visible regression, not a test artifact.

### Why the fix is not at fault

The boundary behaviour is correct and was not weakened. The gap is that
`Mix.Tasks.Anemos.Run` has no way to say where it is standing: `extract_event/1`
(`lib/mix/tasks/anemos.run.ex:58`) parses only `--event`, and `Anemos.run/2` is handed no
context.

This also explains a pre-existing complaint in the usability audit (§10.6): context-scoped
rules were untestable from the CLI, and the context feature could not be demonstrated at
all. The old behaviour hid that by matching everything.

### What should change

Thread a `--context` flag through `Mix.Tasks.Anemos.Run` into `Anemos.run/2`. Use
`OptionParser` rather than extending the hand-rolled `chunk_every/4` scan, which silently
ignores unknown flags.

---

## L-01 — `Anemos.Runtime.RuleSupervisor` is dead code that ships in the published docs

**Filed:** 2026-08-04 · **Reported from:** as-built architecture review

### Symptom

`Anemos.Runtime.RuleSupervisor` is referenced by exactly one line in the whole tree — its
own `defmodule`:

```text
$ grep -rn "RuleSupervisor" --include=*.ex --include=*.exs lib test
lib/anemos/runtime/rule_supervisor.ex:1:defmodule Anemos.Runtime.RuleSupervisor do
```

It is not in the `Anemos.Runtime` supervisor's child list (`lib/anemos/runtime.ex:169-181`
starts `ModuleRegistry`, `ContextStore`, `Dispatcher`, `Scheduler` — nothing else), and
`Anemos.Application` starts no children at all. Nothing calls
`RuleSupervisor.start_link/1`.

The module's own moduledoc admits its status (`lib/anemos/runtime/rule_supervisor.ex:2-7`):

```text
Minimal structure for v0.1.0 — ready to supervise per-rule
GenServers when stateful rule execution is needed.
```

Despite that, `doc/` ships it as a live API page:

```text
$ ls doc/ | grep RuleSupervisor
Anemos.Runtime.RuleSupervisor.html
Anemos.Runtime.RuleSupervisor.md
```

A reader of the generated documentation has no way to tell this supervisor from the ones
the runtime actually starts.

### Why it happens

ExDoc documents every public module it finds. Placeholder modules written ahead of the
feature that will use them are indistinguishable, in the output, from load-bearing ones.

### What should change

**Resolved by decision, 2026-08-06:** per-rule supervision *is* on the roadmap.
`RuleSupervisor` becomes the per-rule tier — a `DynamicSupervisor` hosting a per-rule child
supervisor, started on demand when a rule needs to consume a rule-scoped store. A separate
`StoreSupervisor` takes stores-as-infrastructure. See A-01.

---

## L-02 — `Anemos.Runtime.DataModelRegistry` is exercised only by its own tests

**Filed:** 2026-08-04 · **Reported from:** as-built architecture review

### Symptom

Outside its own definition, `DataModelRegistry` appears only in a test file and in one
unrelated moduledoc:

```text
$ grep -rn "DataModelRegistry" --include=*.ex --include=*.exs lib test
lib/anemos/runtime/data_model_registry.ex:...   (definition + doctests)
lib/anemos/runtime/subscribable_registry.ex:5:  Unlike `DataModelRegistry` (which derives the key from the handler via
test/anemos/data_model_test.exs:5,17,18,19,24,25,26
```

No process starts it. `Anemos.Runtime.init/1` (`lib/anemos/runtime.ex:169-181`) does not
list it among its children, and `Anemos.Runtime.Dispatcher.init/1` starts `TripleStore`,
`DataStore` and `SubscribableRegistry` (`lib/anemos/runtime/dispatcher.ex:125-129`) but
never `DataModelRegistry`.

The result: the `Anemos.DataModel` behaviour has a registry that no running system
consults. Format-keyword lookup exists as a tested function and as nothing else.

### Why it happens

**The original diagnosis in this entry was wrong, and is corrected below. Retained rather
than deleted so the reasoning is auditable.**

> ~~`SubscribableRegistry` was added later with an overlapping job — the comment at
> `lib/anemos/runtime/subscribable_registry.ex:5` contrasts the two — and the dispatcher
> was wired to the newer one. The older registry was left in place.~~

### Corrected diagnosis, 2026-08-06

The two registries **do not overlap**. They are a designed pair, and
`docs/superpowers/specs/2026-04-15-data-query-blocks-design.md` says so explicitly:

```text
:131  Optional behaviour for handlers that support dynamic subscription.
      Separate from `Anemos.DataModel` — a handler may implement one or both.
:141  The protocol identifier in `subscribe <protocol> <uri>` is looked up in a
      separate subscribable registry.
:198  {:format_block, keyword, raw} — look up keyword in DataModelRegistry ...
:204  Validate engine keyword in DataModelRegistry
```

`Anemos.DataModel` is keyed by **format keyword** (`"edn"`, `"xml"`, `"sql"`).
`Anemos.Subscribable` is keyed by **protocol**. Both behaviours exist in `lib/` today, one
registry each. Deleting `DataModelRegistry` would delete half a designed pair and leave
`Anemos.DataModel` with no lookup path at all.

The misreading was invited by the moduledoc at `subscribable_registry.ex:5`, which
contrasted the two registries on registration signature without ever saying what each was
*for*. That moduledoc has been rewritten.

`DataModelRegistry` is not residue left behind by a newer design. It is the one piece of
the data-format feature that got built first.

### What is actually wrong

The format path is **unimplemented and fails silently** — filed separately as A-34 and
A-35. The spec names the exact place the registry belongs (`:198`, `:204`) and neither
call site was ever built. What is missing is compiler and dispatcher wiring plus at least
one concrete handler; there is no EDN handler anywhere in `lib/`.

### What should change

Keep `DataModelRegistry` and its tests. Retitle this entry's substance to A-34/A-35 — the
silent-drop defects — and mark the module `@moduledoc false`, or exclude it from the ExDoc
groups, until its consumer exists. That is the same treatment L-01 proposes for the same
class of problem: a module built ahead of its consumer should not ship as live API.

**No deletion. The 2026-08-04 entry offered deletion as one of two resolutions; on the
spec evidence above that is the wrong branch.**

---

## L-03 — `Anemos.Application` starts no supervision tree

**Filed:** 2026-08-04 · **Reported from:** as-built architecture review

### Symptom

`lib/anemos/application.ex:15` declares an empty child list:

```elixir
def start(_type, _args) do
  # Re-discover Comn registries now that Anemos modules are loaded
  Code.ensure_loaded!(Anemos.Runtime.Errors)
  Comn.Errors.Registry.discover()
  Comn.Discovery.discover()

  children = []

  opts = [strategy: :one_for_one, name: Anemos.Supervisor]
  Supervisor.start_link(children, opts)
end
```

The application callback's entire effect is the two `discover/0` calls. The supervisor it
starts has nothing to supervise; `Anemos.Supervisor` exists as a named process with zero
children.

This is not by itself a bug — Anemos is a library whose runtime is started by its host —
but it means the OTP application boundary carries no information about what the system
runs. Every claim about "the supervision tree" has to be read out of `Anemos.Runtime`,
which callers start themselves.

### What should change

Either document in the moduledoc (currently `@moduledoc false`) that this is a library
application whose supervision tree is host-started via `Anemos.Runtime.start_link/1`, or
fold the discovery calls into a proper child and drop the empty supervisor. The current
shape gives a reader no signal either way.

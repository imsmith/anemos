# Anemos: Post-Acquisition Technical Codebase Analysis

**Date:** 2026-08-06
**Version:** 0.1.0
**Commit:** `80ba1b4` (branch `main`, 128 commits, no other branches)
**Working tree:** dirty — `mix.lock` and `stop-data-extraction-policy.tcl` modified; one untracked file with a corrupted name
**Context:** Forensic due-diligence review of an inherited Elixir/OTP codebase. Five independent analysts covered architecture, security, data flow, usability, and code quality. Findings below are correlated across those five reports; where they disagreed, the disagreement is recorded and resolved.

**Method note.** Three of the five analysts executed the code rather than only reading it. Findings marked **[REPRODUCED]** were demonstrated against a live runtime, in some cases independently by two analysts. That distinction matters: the most serious defects in this report are not inferences.

---

## Executive summary

Anemos is an Elixir library implementing a DSL for event-driven automation policy, plus an in-process interpreter for it. It is not a service: no HTTP layer, no database, no frontend, no external process.

The codebase splits cleanly in two, and the two halves are of markedly different quality.

**The language front end is careful work.** Lexer, parser, AST, and compiler total ~3,700 lines; 403 tests and 20 doctests pass in ~3 seconds; there are zero `TODO`/`FIXME` comments, zero compiler warnings, `@moduledoc` on every public module, a 514-line README that is accurate, and an `ISSUES.md` that self-reports the project's own dead code with grep evidence and line citations. The commit history shows spec → plan → implement → test executed consistently.

**The runtime process layer did not receive the same treatment.** It is one unsupervised GenServer that acts as router, interpreter, effect executor, and owner of all mutable state. Four defects in that layer were reproduced against a running system, three of which cause silent, total, unrecoverable loss of function:

1. Any child-process crash silently discards every loaded policy; the system then reports success on every event forever.
2. Two rules that reference each other spin the dispatcher at 100% CPU with no termination.
3. Operations leak between unrelated rules through the process dictionary — rule A's effects execute a second time under rule C's name.
4. Every `condition` in the language fires unconditionally; the trigger expression is parsed and never compiled.

Separately, the security posture has a specific and correctable shape: **Anemos advertises a security vocabulary it does not implement.** `signed_by` is parsed and never verified. `context` is documented as an exclusionary boundary and fails open. `capability`/`demand` scoping is stored and never read. Meanwhile the project's own canonical example routes an unlocked credential through a default channel connector that `inspect`s payloads into the application log.

Finally, **the repository cannot be built by anyone else.** `{:comn, path: "../comn"}` is an unpublished sibling checkout with no git ref and no version, and path dependencies cannot be pinned in `mix.lock`.

**Bottom line for an acquirer:** the DSL design and its front end are a real asset worth keeping. The runtime needs Phase 0 and Phase 1 work below before it runs anything unattended. None of the defects are architecturally unfixable — they trace to a single structural decision (§5.1) and a single unmade product decision (§3.7).

---

## 1. Architecture

### 1.1 System overview

| Property | Value | Source |
|---|---|---|
| OTP application | `:anemos` | `mix.exs:8` |
| Version | 0.1.0 | `mix.exs:9` |
| Elixir requirement | `~> 1.19` (running 1.19.5 / OTP 28) | `mix.exs:10` |
| License | AGPL-3.0-or-later (`mix.exs`); README says "AGPL-3.0" | `mix.exs:22` |
| Source | 6,455 lines / 39 `.ex` files in `lib/` | measured |
| Tests | 6,577 lines / 38 files; 403 tests + 20 doctests, 0 failures | `mix test` |
| Coverage | 73.53% (below the 90% default threshold — `mix test --cover` fails) | `mix test --cover` |

The pipeline is four stages, all in-process and synchronous:

```text
.rule source
    │  Anemos.Lexer.tokenize/1      NimbleParsec → flat token list
    ▼
tokens
    │  Anemos.Parser.parse/1        recursive descent + 14-level precedence climbing
    ▼
%Anemos.AST.Program{}
    │  Anemos.Compiler.compile/1    AST → Elixir closures (no code generation)
    ▼
%Anemos.CompilationResult{}
    │  Anemos.Runtime.Dispatcher    GenServer: event → rule index → closure → operations
    ▼
[{:ok, op} | {:error, reason}]
```

The compiler explicitly does **not** generate modules (`compiler.ex:81`: "No code generation, no `Module.create`"). Rules become arity-3 anonymous functions closing over AST fragments, re-interpreted on every firing. The system is an AST-walking interpreter wearing a compiler's naming; per-event cost is proportional to statement count and is not amortized.

*This is also the single best security decision in the codebase* — see §3.8.

### 1.2 Technology stack

Elixir/OTP on the BEAM. Three direct dependencies:

```elixir
{:comn, path: "../comn"},          # unpublished local path dependency
{:nimble_parsec, "~> 1.4"},        # lexer combinators, current at 1.4.2
{:ex_doc, "~> 0.35", only: :dev}   # docs only
```

There is no web framework, no Ecto, no database driver used, no HTTP client, no `Task`, no `Port`, no `System.cmd`.

### 1.3 Module map

**Language front end**

| Module | Lines | Role |
|---|---:|---|
| `Anemos.Lexer` | 554 | NimbleParsec tokenizer; emits `{type, [line: n], value}` |
| `Anemos.Parser` | 1,946 | Recursive descent; ~50 `defp parse_*` clauses; largest artifact by 2× |
| `Anemos.AST` | 258 | 28 plain structs, all carrying `:line` |
| `Anemos.Compiler` | 911 | AST → closures |

`Anemos.Parser` carries the most concentrated risk: there is no grammar artifact anywhere. The grammar exists only as pattern-match ordering, and the module has the worst coverage of any core file (66%).

**Runtime**

| Module | Lines | Process type | Started by |
|---|---:|---|---|
| `Anemos.Runtime` | 218 | Supervisor (`:one_for_one`) | host application |
| `Anemos.Runtime.Dispatcher` | 664 | GenServer | Runtime supervisor |
| `Anemos.Runtime.Scheduler` | 222 | GenServer | Runtime supervisor |
| `Anemos.Runtime.ModuleRegistry` | 72 | Agent | Runtime supervisor |
| `Anemos.Runtime.ContextStore` | 58 | Agent | Runtime supervisor |
| `Anemos.Runtime.ConditionServer` | 85 | GenServer × N | **Dispatcher (unsupervised)** |
| `Anemos.Runtime.CapabilityServer` | 60 | GenServer × M | **Dispatcher (unsupervised)** |
| `Anemos.Runtime.TripleStore` | 128 | Agent | **Dispatcher (unsupervised)** |
| `Anemos.Runtime.DataStore` | 233 | GenServer | **Dispatcher (unsupervised)** |
| `Anemos.Runtime.SubscribableRegistry` | 75 | Agent | **Dispatcher (unsupervised)** |
| `Anemos.Runtime.DataModelRegistry` | 76 | Agent | **never started — dead** |
| `Anemos.Runtime.RuleSupervisor` | 27 | DynamicSupervisor | **never started — dead** |

`RuleSupervisor` has exactly one reference in the entire tree: its own `defmodule` line. It is the `DynamicSupervisor` that would fix the codebase's worst defect, and it has never been wired in. Both dead modules are correctly self-reported in `ISSUES.md` and both still ship in the published ExDoc output as live API.

### 1.4 Extension points

| Module | Kind | Live consumer? |
|---|---|---|
| `Anemos.Runtime.Module` | behaviour — `handle_verb/3` | yes |
| `Anemos.Module` | macro — `use ... , name: "X"` | yes |
| `Anemos.Event` | protocol | yes |
| `Anemos.Channel` | behaviour — `publish/2` | yes |
| `Anemos.Subscribable` | behaviour | partially — `subscribe/3` only |
| `Anemos.DataModel` | behaviour | **no — nothing calls any of its four callbacks** |

The `Anemos.Module` extension point is the best-designed surface in the system: `use Anemos.Module, name: "SECRET"` plus `verb :unlock, &Comn.Secret.unlock/2` and you are done.

### 1.5 Communication architecture

Everything is BEAM-local. No wire protocol, no serialization format, no port binding.

| Boundary | Mechanism |
|---|---|
| host → runtime | `GenServer.call` via `Anemos.Runtime` API |
| Dispatcher → ConditionServer | async `cast`, then a `call` used purely as a memory barrier |
| ConditionServer → Dispatcher | raw `send/2` from a closure |
| Dispatcher → host verb modules | **direct function call**, in-process, no isolation |
| Dispatcher → channel | direct call `connector.publish(path, %Envelope{})` |

The barrier pattern is worth naming: the dispatcher casts to every condition server, then calls `get_state` on every one solely because a call cannot be answered before the earlier cast is processed, then selectively `receive`s transition messages out of its own mailbox. It works, but it is an ad-hoc rendezvous assembled from three primitives where one `call` per condition would do, it costs O(2N) messages per event regardless of relevance, and — as the code itself admits at `dispatcher.ex:335-338` — transitions arriving outside the current dispatch cycle are **silently discarded**. Level-triggered conditions lose edges.

### 1.6 Data architecture

**There is no database.** No migrations, no Ecto, no repo, no SQL. `exqlite` appears in `mix.lock` only because the `comn` path dependency declares it — which does mean building Anemos requires a working C toolchain to compile a SQLite NIF that Anemos never opens.

**Nothing persists across a process restart.** Five in-memory stores:

| Store | Backing | Notes |
|---|---|---|
| `ModuleRegistry` | Agent map | survives dispatcher restart (separately supervised) |
| `ContextStore` | Agent map | **never read by the dispatch path** — see §2.4 |
| `TripleStore` | Agent holding a **list** | O(n) insert with `in` dedup, O(n) query, no retract, unbounded |
| `DataStore` | GenServer map | keyed `{name, scope_tag}`; cleanup path unreachable — see §4.5 |
| `rule_bindings` | Dispatcher state map | holds three different lifetimes in one namespace — see §4.4 |

### 1.7 Concurrency model

```text
host supervision tree
└── Anemos.Runtime (Supervisor, :one_for_one)
    ├── ModuleRegistry   (Agent)
    ├── ContextStore     (Agent)
    ├── Dispatcher       (GenServer)
    │   ├── ConditionServer  × N  ─┐
    │   ├── CapabilityServer × M   │ start_link'd from init/1:
    │   ├── TripleStore            │ LINKED but NOT SUPERVISED
    │   ├── DataStore              │
    │   └── SubscribableRegistry  ─┘
    └── Scheduler        (GenServer)

Anemos.Application → Anemos.Supervisor (:one_for_one, ZERO children)
```

There is no `Task`, no `Task.Supervisor`, no pooling, no back-pressure, no rate limiting, and no `Process.flag(:trap_exit, true)` anywhere in `lib/`. Every `GenServer.call` uses the default 5,000 ms timeout; no call site overrides it.

The dispatcher is a global serialization point per runtime instance. There is no concurrency within a dispatch and no pipelining across dispatches. **The BEAM's central advantage is not being used.**

### 1.8 Configuration system

Effectively absent, and deliberately so ("blank interpreter, everything loads dynamically, no startup config").

```text
config/config.exs   →  import Config      (1 line)
config/dev.exs      →  import Config      (1 line)
config/test.exs     →  import Config      (1 line)
```

`config.exs` never calls `import_config/1`, so `dev.exs` and `test.exs` are not loaded at all. Currently harmless — all three are empty — but it means `config/test.exs` cannot silence Logger, and a full test run prints hundreds of `[info] [anemos] ...` lines that drown real failures.

`grep` finds no `Application.get_env`, `Application.fetch_env`, or `System.get_env` anywhere in `lib/`. All configuration is function arguments at process start.

Child process names are derived by string interpolation on the supervisor name: `:"#{name}.dispatcher"`. If runtime names ever derive from untrusted input, this is an unbounded atom-creation path. Every observed call site uses a compile-time literal, but nothing in the API enforces it, and `Registry` — which would give lifecycle integration for free — is not used anywhere.

### 1.9 Build and deployment

| Aspect | State |
|---|---|
| Build tool | Mix; `mix.exs` itself is clean and correct |
| CI/CD | **none** — no `.github/`, no pipeline of any kind, 128 commits |
| Linting | **none** — no Credo, no Dialyzer, no Sobelow, no PLT |
| Formatter | `.formatter.exs` correct; `mix format --check-formatted` **currently fails** on `parser.ex` |
| Coverage gate | none configured; actual 73.53% vs 90% default |
| Docker / releases | none |
| Reproducible build | **no** — see below |

**The repository is unbuildable by anyone but its author.** `{:comn, path: "../comn"}` resolves to a sibling checkout with no git URL, no version, and no fallback. Path dependencies do not appear in `mix.lock`, so the single most important dependency has no recorded version. `comn` is not incidental: it supplies `Comn.Errors.Registry`, `Comn.Contexts`, `Comn.Discovery`, `Comn.EventBus`, and the `@behaviour Comn` implemented by five modules. Anemos cannot compile without it and cannot tell you which version it needs. Publishing to Hex is impossible in this state.

`mix.lock` is simultaneously tracked in git **and** listed in `.gitignore` — the two declarations contradict, and the file currently shows as modified.

---

## 2. Concept of Operations

### 2.1 Three entry points

1. **`Anemos.run/2`** — one-shot. Parses, compiles, starts a throwaway registry and dispatcher, dispatches one event, stops both. **[REPRODUCED]** it leaks 4 processes per call (§4.2). Scripts and tests only.
2. **`Anemos.Runtime`** — the supported integration path. A Supervisor the host starts in its own tree; policies and modules load at runtime.
3. **`mix anemos.run FILE --event EVENT`** — thin CLI wrapper over `Anemos.run/2`.

### 2.2 The dispatch cycle

`Dispatcher.handle_call({:dispatch, ...})` (`dispatcher.ex:147-180`), entirely inside one process:

1. **Build a Comn context** — `request_id` (8 random bytes, base32), `parent_event_id`, `correlation_id`, `trace_id`, `actor`, and `context_path` metadata. The whole cycle runs inside `Comn.Contexts.with_context/2`, which stores the struct in the process dictionary.
2. **Fan out** an async `cast` to every condition server, unfiltered.
3. **Barrier** — a synchronous `get_state` to every condition server purely to force the casts to drain.
4. **Drain transitions** — non-blocking selective `receive` for `{:condition_transition, name}`.
5. **Dispatch to rules** — event name → `state.index` map → context filter → immediate run or dwell state machine.
6. **Dispatch synthetic condition events** — each transition becomes a `CONDITION_<name>` event through the same path.

### 2.3 Per-rule execution

`dispatch_immediate/5` loads the rule's persistent bindings, enriches context with the `DataStore` pid and `:_rule_name`, calls the handler inside `safe_handle/4`, writes bindings back, then executes each operation.

`safe_handle/4` rescues eight named exception types plus a bare `catch kind, reason`. The comment claims unexpected types are "left to crash and restart via the supervisor," but the bare catch contradicts that for throws and exits. The `rescue` list is explicitly and thoughtfully bounded; the `catch` below it undoes that discipline — and it swallows `GenServer.call` timeout exits from module verbs, converting a system-level failure into a hidden rule-level error.

Operation types: `:command`, `:log`, `:emit`, `:demand`, `:assert_triple`, `:triple_query`, `:nextevent`, `:nextrule`, `:register_data`, `:register_query`. The last two are **dead** — the compiler moved inline data registration to load time and explicitly skips them at runtime, so no code path can emit them. The `recon/0` introspection map lists only eight of the ten.

### 2.4 Variable resolution

| Sigil | Meaning | Created by | Resolves from |
|---|---|---|---|
| `?name` | external context data | environment | `context[:context_data][name]` |
| `@name` | immutable, ephemeral | `let` | `bindings[{:let, name}]`, discarded after each firing |
| `$name` | mutable, persistent | `set` | `bindings[{:set, name}]`, survives firings |

Only `{:set, _}` keys survive: `build_handler/1` filters the final binding map before returning.

**`Anemos.Runtime.put_context/3` does not feed `?` resolution.** `ContextStore` is written by the public API and read by nothing in the dispatch path — `ContextStore.resolve/3` has no caller in `lib/` outside its own doctest. A host that calls `put_context/3` and expects `?fqdn` to resolve gets `nil`. The README documents this link; the code does not implement it.

### 2.5 Scheduling

`at` blocks compile to a synthetic event name derived **purely from the time spec** (`AT_08_00`, `AT_INTERVAL_5min`, `AT_DAY_monday`, `AT_NLD_next_week`), plus a `CompiledRule` named `at_<event_name>`.

**[REPRODUCED]** Two rules with `at 08:00` produce two schedules and two rules all named `AT_08_00` / `at_AT_08_00`. Consequences: the timer map is keyed by event name, so the second `Map.put` overwrites the first entry and **the first timer is never cancelled and keeps firing**; and both rules share one `rule_bindings` entry, colliding across unrelated policy files.

Other scheduler gaps:

- **Silent no-scheduling.** A past-dated `{:date, ...}` or unresolvable `{:nld, text}` returns `nil`, which is stored in the timers map as if it were a timer ref, and `schedule/2` still returns `:ok`. A schedule that will never fire is indistinguishable from one that will.
- **No removal API.** Timers cannot be cancelled; `state.schedules` grows on every `load/2`.
- **Recurrence is implemented only for `{:time, {h, m}}`.** Recurring day-of-week or date specs fire once and stop.
- **All time arithmetic uses `NaiveDateTime.local_now/0`** — DST-naive by construction. A recurring 02:30 job silently double-fires or skips on transition days.
- Scheduler coverage is **20%**, the lowest of any module, on the module with the most branching.

### 2.6 Dwell timers

`when EVENT for <duration>` runs a state machine keyed `rule_bindings[rule_name][{:dwell, event_name}]`:

```text
:listening + truthy  → :armed      (Process.send_after)
:listening + falsy   → :listening
:armed     + truthy  → :armed      (timer NOT restarted)
:armed     + falsy   → :listening  (cancel_timer)
timer fires          → run body synchronously → :listening
```

Truthiness reads a `"state"`/`:state` key from the payload and **defaults to `true` when neither is present**. An event with no payload always arms and can never be cancelled — the dwell degrades into an unconditional delayed fire. Undocumented.

### 2.7 Persistence and recovery

**There is no persist/restore cycle.** Everything is in memory. A dispatcher restart loses all rules, conditions, capabilities, triples, datasets, `set` bindings, and armed dwell timers. Because `Anemos.Runtime` is `:one_for_one`, the Scheduler survives a dispatcher restart with its timers intact — and then fires `AT_*` events into an empty dispatcher forever.

The only recovery procedure available to a host is "restart and reload everything" — which is also, per §4.3, the way to break the system by doubling every rule.

---

## 3. Security Issues

Anemos has no web layer, so there is no authentication, authorization, CORS, WebSocket, session, cookie, or OAuth code to review. **That absence is itself the finding.** Anemos is a policy engine that executes privileged operations, built with no trust boundary of any kind, while its DSL advertises security controls that are parsed and then ignored.

| Severity | Count |
|---|---:|
| CRITICAL | 2 |
| HIGH | 6 |
| MEDIUM | 8 |
| LOW | 4 |
| INFORMATIONAL | 5 |

### 3.1 CRITICAL — Policy source is loaded and executed with zero trust boundary

`Anemos.Runtime.load/2` (`runtime.ex:56`) accepts an arbitrary source string at runtime, compiles it to closures, and installs it into the live dispatcher. No caller authentication, no authorization, no signature verification, no sandbox, no resource ceiling. It is additionally exposed through the generic `Comn` action surface as `act(%{action: :load, name:, source:})` (`runtime.ex:208`), so anything that can reach the Comn dispatcher can load policy.

Whoever controls a `.rule` string controls every module verb registered in the runtime — including, per the shipped example, the one that unlocks DDNS credentials.

**Fix:** treat `load/2` as privileged. Require a verified signature (§3.3) or restrict it to a supervised bootstrap path reading from a root-owned directory. Remove `:load` from the `Comn.act/1` surface.

### 3.2 CRITICAL — No input validation between DSL/event data and host verbs

`execute_op` for `:command` (`dispatcher.ex:490-497`) passes `args` **verbatim** to `mod.handle_verb/3`. Args arrive from policy literals and from event payloads. There is no argument schema, no type check, no length bound, no allow-list, no escaping, and no taint tracking anywhere in the pipeline. The `Anemos.Module` macro makes it a one-liner to bind a DSL verb directly to a powerful host function — and its own moduledoc uses secret unlocking as the worked example.

Concretely, in the substrate Anemos already depends on: `Comn.Repo.File.Local` calls `File.open/2`, `File.stream!/1`, and `File.write` on caller-supplied paths with **no normalization and no root confinement**. Wire that to a real `FILE` verb — which `runtime/modules/file.ex` exists as a placeholder for — and `[FILE::read "../../etc/shadow"]` is a working path traversal on day one. `Comn.Repo.Cmd.Shell` is declared and currently returns `:not_implemented`; when it lands, the same unguarded path becomes command execution.

The `context` map handed to every verb also carries the live `:data_store` pid — a process handle exposed to every third-party verb implementation.

**Fix:** add an `arg_schema/1` callback to `Anemos.Runtime.Module` enforced by the dispatcher before `handle_verb/3`. Confine every path-taking verb to a configured root via `Path.expand/2` plus a prefix assertion.

### 3.3 HIGH — `signed_by` is parsed and never verified

`parser.ex:163` stores the signer in rule metadata. Grep confirms zero verification code anywhere in `lib/`: no crypto call, no key lookup, no comparison. Likewise `Anemos.Envelope` declares a `:signature` field that no code path ever populates.

This is worse than having no signing. A rule file reading `signed_by :operator.did` looks authenticated to every human and every tool that inspects it, and is accepted identically to an unsigned one. It manufactures false provenance.

**Fix:** implement verification before `load/2` installs the rule, or remove the keyword and the field until it is real.

### 3.4 HIGH — Context isolation fails open (found independently by four analysts)

`context_matches?/2` (`dispatcher.ex:443-450`):

```elixir
defp context_matches?(_rule, nil), do: true

defp context_matches?(rule, event_context) do
  case get_in(rule, [Access.key(:meta), :context_path]) do
    nil -> true
    rule_context -> String.starts_with?(event_context, rule_context)
  end
end
```

Two defects, either of which voids the boundary:

1. **An event with no context path matches every rule.** `Anemos.Runtime.dispatch(:anemos, "EVENT")` omits context by default, so the *simplest and most likely call in any host application* silently disables context isolation entirely. The CLI never sets a context path at all.
2. **[REPRODUCED]** The prefix match has no segment boundary. A rule scoped to `garage` fires on an event from `garageband.amp`.

For a construct documented as an exclusionary boundary in an authorization-adjacent DSL, this is a correctness bug wearing a usability disguise.

**Fix:** default-deny when a rule declares a context and the event has none; compare path segments, not raw string prefixes.

### 3.5 HIGH — Capability context scoping is decorative

`CapabilityServer` takes a `:context` at init, stores it, and **never reads it again**. `handle_call({:execute, context}, ...)` invokes the handler unconditionally, and `Demand.evaluate/3` looks capabilities up in a flat map with no comparison against the demanding rule's context. The `context infra.networking` line in the shipped ddns example constrains nothing: any rule in any context can `demand katachora-ddns-key` and receive the unlocked secret.

Combined with §3.4, **there is no working scope isolation anywhere in the runtime.**

### 3.6 HIGH — Unbounded atom creation from policy text can kill the node

`lexer.ex:504` calls `String.to_atom(value)` on **every identifier token** — converting first and checking keyword membership second, so non-keyword identifiers are interned as a side effect of the test. Five more sites do the same for duration units, `DAY_*` literals, demand flags, recurrence names, and `expect` lists.

Atoms are never garbage collected. Exceeding the table limit is an unrecoverable `system_limit` abort of the **entire BEAM node**, not a supervised process crash. Since `load/2` is designed to be called repeatedly at runtime, one policy with ~1M unique identifiers takes the node down permanently. Note the asymmetry: a policy *parse failure* is recoverable; atom exhaustion is not.

**Fix:** at `lexer.ex:504`, match against a compile-time `MapSet` of keyword **strings** and never convert unmatched identifiers. Use `String.to_existing_atom/1` with a rescue at the other five closed-set sites.

### 3.7 HIGH — Default channel connector logs full payloads, and the canonical example routes a secret through it

`Anemos.Channel.Logger` — the **default** connector, chosen specifically so emits are "never silent" — does `Logger.info("... #{inspect(envelope.payload)}")`. The `:log` operation does the same.

The shipped `priv/examples/ddns.rule` demonstrates obtaining a secret by emitting it:

```text
on demand {
  emit [SECRET::unlock(agent.did_...operator.security:did_key_67890)]
    as :katachora.ddns.key
}
```

With the default connector, the unlocked secret is `inspect`ed into the application log at `:info` and from there into whatever ships logs off the host. No redaction exists anywhere: no `Inspect` protocol override, no `:redact` marking, no sensitive-value wrapper type.

**Fix:** a wrapper struct for secret-bearing values with a custom `Inspect` rendering `#Secret<redacted>`; `Channel.Logger` should log payload type and size, never contents.

### 3.8 HIGH — `ModuleRegistry` is an unprotected Agent; verb routing can be hijacked

`register/3` is `Agent.update(registry, &Map.put(&1, name, module))` — last write wins, no authorization, no immutability, no duplicate detection. Any process that can name the registry (`:"#{name}.registry"`, a public documented convention) can rebind `"SECRET"` or `"INFRA"` to an attacker-chosen module. Every subsequent `[SECRET::unlock ...]` dispatches to it with arguments intact, and the policy behaves normally from outside.

`SubscribableRegistry` and `ContextStore` have the same shape. `ContextStore` holds the values `?variable` dereferences resolve to, so writing it steers rule logic.

This requires in-VM code execution to exploit, which is why it is HIGH rather than CRITICAL — but on the BEAM, "another application in the same release" is a routine adversary.

### 3.9 MEDIUM findings

| # | Finding |
|---|---|
| M-1 | **Demand fails open on unknown capabilities.** Under `:optional` or `:sufficient`, a capability that *does not exist* is treated like one that merely failed, and the stack can return `{:ok, results}` having authorized nothing. A typo in a capability name silently disables the gate. PAM flag semantics govern *failure*; "not loaded" is a configuration error and should be fatal regardless of flag. |
| M-2 | **Unbounded timers.** `Duration.to_ms/1` applies no floor, ceiling, or sanity check, and there is no cap on schedules per policy. A 1 ms interval installs a 1000 Hz loop of synchronous calls into the sole dispatcher. `to_ms/1` also has no catch-all clause — an unrecognized unit raises inside `Scheduler.init/1`. |
| M-3 | **Internal error detail returned to callers.** `Exception.message/1` is returned verbatim; `KeyError` and `BadMapError` embed the full offending term. In a runtime handling secrets, a `KeyError` on a map containing an unlocked credential prints that credential into the error result — and via the Mix task, onto the console. |
| M-4 | **Unsafe deserialization in `comn`.** `:erlang.binary_to_term(payload)` **without `[:safe]`** at three sites in the SQLite queue. The same repo's `Comn.Secrets` gets this right, so it is an oversight, not a policy. One-word fix. |
| M-5 | **NATS defaults to plaintext, unauthenticated.** `comn`'s NATS transport defaults to `127.0.0.1:4222` with TLS off and no credential options plumbed at all, despite `nkeys`/`kcl` being present. `Anemos.Channel` documents NATS as an intended connector. |
| M-6 | **Weak key derivation in `Comn.Secrets.Local`** — the code documents its own defect: `:crypto.hash(:sha256, key.private)` with no salt and no context separation, reusing an Ed25519 *signing* key for ChaCha20 encryption. No rotation path, no key versioning. Nonce handling is correct. |
| M-7 | **`erl_crash.dump` (5.9 MB)** from 2026-04-16 in the working tree. Correctly gitignored, so it will not reach the remote, but heap dumps routinely contain credentials. A string scan found only test fixture material, so no live secret is known to be exposed. Delete it; it is a standing liability. |
| M-8 | **`mix.lock` in `.gitignore`.** Tracked anyway, so the immediate effect is only that lockfile changes are easy to miss — but the intent conflicts with the project's own SPDX/SBOM standard. |

### 3.10 Positive security findings

- **No code generation on untrusted input.** No `Code.eval*`, no `Code.compile*`, no `Module.create`, no `EEx`, no `apply/3` anywhere in `lib/`. Verified by grep. This materially limits the blast radius of malicious policy text to the verbs the host has registered, and it is the single best security decision in the codebase. Note that `CLAUDE.md`'s description of the compiler as producing "executable rule modules" is misleading on exactly this point — the code is safer than the documentation implies.
- **SQL is parameterized.** Every query in `comn`'s SQLite queue uses prepared statements with `?` placeholders. The interpolated `#{order}` fragments derive from a boolean over a compile-time literal pair and are not injectable.
- **Request-id generation is sound** — `:crypto.strong_rand_bytes(8)`, correct primitive (though 64 bits is a correlation id, not a security token).
- **Dependency posture is current.** 28 packages, no retired, abandoned, or known-vulnerable ones. Elixir 1.19.5 / OTP 28 are current. No CVE scan was run; `mix hex.audit` against a live advisory database is recommended.

### 3.11 The structural security recommendation

Items §3.3–§3.5 and §3.1–§3.2 keep returning to one root cause: **Anemos declares a security model — signed rules, context boundaries, capability gating — implements none of it, and is already wired to secret unlocking and infrastructure verbs.**

Before adding language features, decide explicitly which of these Anemos is:

1. **A trusted-operator engine.** Policy text is as privileged as source code. Then delete `signed_by`, stop describing `context` as a boundary, and document loudly that `load/2` is equivalent to `eval`. Cheapest, and honest.
2. **A multi-tenant policy engine.** Policy is untrusted input. Then §3.1–§3.5 are not hardening — they are the product, and they need designing before more surface accumulates.

The current state is the worst of both: the security vocabulary of option 2 with the trust assumptions of option 1.

---

## 4. Quality Issues

| # | Area | Grade |
|---|---|---|
| 1 | Code organization | ADEQUATE |
| 2 | Error handling | POOR |
| 3 | Test coverage | ADEQUATE |
| 4 | Type safety | POOR |
| 5 | Code smells | ADEQUATE |
| 6 | Dependency health | POOR |
| 7 | Naming | ADEQUATE |
| 8 | Architectural debt | CRITICAL |
| 9 | Build and CI | POOR |
| 10 | Documentation | GOOD |
| 11 | Elixir/OTP correctness | CRITICAL |
| 12 | Frontend | N/A |

### 4.1 [REPRODUCED] Any child crash silently destroys every loaded policy

**The single worst defect in the tree.** Confirmed independently by two analysts.

`Dispatcher.init/1` `start_link`s every `ConditionServer`, `CapabilityServer`, the `TripleStore`, the `DataStore`, and the `SubscribableRegistry`. These are *linked* to the dispatcher and supervised by nobody. The dispatcher does not trap exits. `ConditionServer.handle_cast/2` invokes a user-supplied evaluator closure **with no rescue**, so any exception in a policy's condition expression kills the condition server, which kills the dispatcher.

The Runtime supervisor then restarts the dispatcher with the child spec at `runtime.ex:172-177` — `rules: [], conditions: [], capabilities: []`.

```text
ops before crash: 1
same dispatcher pid? false     (it restarted)
ops after crash:  0
```

Every policy is gone. `dispatch/3` returns `{:ok, []}` — **byte-identical to "no rule matched"** — forever. No error, no log, no supervisor message the host can observe. A production system would silently stop enforcing every policy it had loaded and continue reporting success on every event.

This converts every recoverable policy bug into total, undetectable loss of function. It is not recorded in `ISSUES.md`.

### 4.2 [REPRODUCED] Unbounded event recursion wedges the dispatcher permanently

Three op types recurse into `dispatch_to_rules/3` with no depth counter, no visited set, and no cycle detection: `:emit` with a label, `:nextevent`, and `:nextrule`.

```text
rule a { when A { log "a" nextevent B } }
rule b { when B { log "b" nextevent A } }
```

Reproduced: **no termination within 4 s.** The calling process dies at the 5 s timeout; the dispatcher keeps recursing at 100% CPU, growing its stack, until the VM dies. Every other event in the system blocks behind it.

Note the contrast: `while` loops **are** bounded (`@while_limit 10_000`). The author knew to bound unbounded iteration in one place and missed the other. Per NASA Power of 10 rule 2 — which this project's own doctrine adopts — every loop needs a fixed upper bound, and event recursion is a loop. (`for` loops, meanwhile, have no bound at all, and `while`'s bound **truncates silently** with no error, no log, and no marker in the result.)

### 4.3 [REPRODUCED] Process-dictionary flow control leaks operations between unrelated rules

The compiler implements `return`/`done`/`nextevent`/`nextrule` as `throw`, using `Process.put(:anemos_accumulated_ops, ...)` to carry the in-flight accumulator past the throw. The mechanism is deliberate and well commented.

It is also unbalanced. `eval_body/3` restores the previous value **only on the normal exit path**; `build_handler/1` catches the throw and never restores the key. A handler that hits `return` leaves its ops in the process dictionary, and the next handler in that process prepends them to its own output.

```text
rule a (return):          {:ok, [%{type: :log, value: "a1"}], %{}}
process dict after throw: [%{type: :log, value: "a1"}]
rule c after leak:        {:ok, [%{type: :log, value: "a1"}, %{type: :log, value: "c1"}], %{}}
```

`rule c` emitted `rule a`'s operation. In production every rule runs in the one long-lived dispatcher process, so the leak is permanent and cross-policy. Here the leaked op was a `log` — but the same path carries `:command` ops, so **a device or file command from one rule can be re-executed by an unrelated rule** that happens to use `return`. Silent, non-deterministic (it depends on rule ordering within the index), and invisible in the result list, which simply shows one extra operation.

**Analyst disagreement, resolved.** The architecture analyst read this same code and concluded the process-dictionary usage was "deliberate, commented with its rationale, and correct for the single-process execution model it assumes." Two other analysts reproduced the leak against a running system. The empirical result stands: the mechanism is correct on the normal path and unbalanced on the throw path, which is precisely the path it exists to serve.

### 4.4 Every `condition` fires unconditionally

`compiler.ex:204`:

```elixir
evaluator = fn _event_name, _context -> true end
```

Independently verified during synthesis. The trigger expression is parsed and never compiled into the evaluator, so every condition transitions `false → true` on the first subscribed event it sees regardless of its stated trigger. Condition bodies compile to a `side_effect_handler` whose returned operations are then **discarded** by the server (`condition_server.ex:75`) — only the synthetic `CONDITION_<name>` event escapes.

Conditions are the DSL construct users would reach for to express "only when X," and they currently express "whenever anything happens."

### 4.5 State-integrity defects

- **[REPRODUCED] Duplicate `load/2` doubles execution.** `state.rules ++ compiled.rules` with no dedup on rule name and no replace semantics. Accumulation is documented as intended, but there is no `unload`, no `replace`, no warning on a duplicate name, and no way to inspect what is loaded. Any hot-reload story on this API double-fires every rule. Re-loading a policy that redefines a condition also **orphans** the previous `ConditionServer` — it stays alive, stays linked, and is unreachable.
- **[REPRODUCED] `nextrule`/`nextevent` discard state.** `:nextevent` binds `{results, _state}` and throws the state away; `:nextrule` discards `_new_persistent`. A rule maintaining a counter produces correct output when called directly and silently resets every time it is reached via `nextrule`. `nextrule` also passes a synthetic event name no subscription can match, and drops the `args` the compiler resolved — `nextrule foo { a: 1 }` parses, compiles, and the arguments go nowhere.
- **[REPRODUCED] A sibling `when` block destroys armed dwell state.** `rule_bindings` is keyed by rule name only, but a rule with multiple `when` blocks compiles to multiple `CompiledRule` structs sharing that name. `dispatch_immediate` overwrites the entry with the handler's `{:set, _}`-filtered output, wiping any `{:dwell, _}` key. The pending timer still fires, finds no entry, and is **dropped silently as "stale."** The dwell body never runs and nothing reports it. There is an explicit 20-line workaround for the case where the dwell body itself fires; it does not cover the sibling case. Same root cause: `handle_info({:dwell_fire, ...})` uses `Enum.find` on rule name, so two `when` blocks watching the same event collapse to one.
- **[REPRODUCED] `Anemos.run/2` leaks 4 processes per call** — 80 leaked across 20 calls, never reclaimed. `GenServer.stop/1` exits `:normal`, which non-trapping linked processes ignore. Harmless for the CLI (the VM exits); unbounded for any host calling it in a loop.
- **`DataStore` scope discriminators are inconsistent and cleanup is unreachable.** `member?/4` accepts a rule-name string as the scope hint; `get/2` hardcodes `self()`, so `get` can never reach a rule-scoped entry. `maybe_monitor/2` only monitors pids, and the dispatcher always passes strings, so the `:DOWN` cleanup handler is unreachable in practice. Every policy reload adds entries that are never removed. The moduledoc says the scope is `{:local, pid}`; the live callers pass `{:local, String.t()}`.
- **`TripleStore` is an unbounded list with linear dedup** — O(n) insert, O(n) query, O(n²) to build, no retract, no size limit, no persistence. A rule asserting one triple per event degrades continuously and then exhausts memory. A `MapSet` (used elsewhere in this codebase) fixes the constant factor; the unboundedness needs a real answer.

### 4.6 Error handling — POOR

Three mutually incompatible error representations coexist:

| Style | Example |
|---|---|
| Structured Comn error | `Comn.Errors.Registry.error!("anemos.runtime/handler_crash", ...)` (`dispatcher.ex:437`) |
| Ad-hoc tuple | `{:error, {:handler_crash, rule.name, reason}}` (`dispatcher.ex:571`) |
| Bare string | `{:error, "Lexer error on line #{line}: ..."}` (`parser.ex:62`) |

The *same logical failure* — a rule handler crashing — produces a structured error on the `dispatch_immediate` path and a raw 3-tuple on the `nextrule` path. Callers cannot pattern-match uniformly on anything. `demand` on a missing capability returns a bare `{:error, {:unknown_capability, name}}`, bypassing the error registry entirely.

Beyond that:

- **`Anemos.Runtime.load/2` discards its own results.** `Dispatcher.load/2` and `Scheduler.schedule/2` return values are thrown away; the function returns a hardcoded `:ok`. Only parse/compile failures ever reach the caller.
- **`dispatch/3` always returns `{:ok, results}`** even when every element is an error. The success/failure distinction is buried in the payload.
- **Subscription failures are logged and dropped.** A data block whose feed fails to subscribe silently becomes an empty `MapSet`, so every `memberof()` check against it quietly returns `false`. For an allow/deny-list use case — the documented use case — fail-open is the wrong default and the caller is never told.
- **Channel publish results are discarded.** A connector returning `{:error, reason}` is indistinguishable from success and the emit still reports `{:ok, op}`.
- **`ConditionServer` and `Scheduler` have no crash boundary at all** — user closures run bare. `CapabilityServer` *does* rescue. The inconsistency is the direct cause of §4.1.

### 4.7 Type safety — POOR

- **~66 `@spec` across 609 function definitions.** Twenty modules have zero, including all of `Anemos.AST`, `Anemos.Module`, `Anemos.Channel`, and both stub verb modules.
- **No Dialyzer, no Credo, no static analysis of any kind.** Nothing has ever checked the specs that do exist for consistency.
- **The core value in the system is an untyped closure.** Every operation is a bare `map()` with a `:type` key. `execute_op/3` dispatches on `%{type: :command}`, `%{type: :log}`, … with no struct, no `@type operation ::` union, and no compile-time check that the compiler and dispatcher agree on the vocabulary. The two lists are kept in sync by hand and by moduledoc. This is the type-safety hole that actually matters here — and §2.3's two dead op clauses are what it looks like when the hand-sync slips.
- `Map.get(rule, :dwell_duration_ms)` treats a struct as a bare map, defeating `@enforce_keys` and hiding typos behind a `nil` default.

Where contracts exist they are good: the behaviours are fully typed and the struct `@type t` definitions are sound. The gap is implementations, not contracts.

### 4.8 Test coverage — ADEQUATE

403 tests + 20 doctests, 0 failures, 3.1 s. 29 test files, 821 assertions, 22 of 38 case declarations `async: true`. Doctests serve as executable documentation in 12 modules, so README-style examples cannot silently rot. Error paths are tested, not just happy paths. This is better than most projects of this age.

Against that:

```text
Coverage: 73.53%   Threshold: 90.00%   →  mix test --cover FAILS
```

| Module | Coverage |
|---|---:|
| `Anemos.Runtime.RuleSupervisor` | 0.00% |
| `Mix.Tasks.Anemos.Run` | 0.00% |
| `Anemos.Runtime.Scheduler` | 20.00% |
| `Anemos.Parser` | 66.03% |
| `Anemos.Runtime.Dispatcher` | 85.65% |

The Scheduler at 20% is the alarming number — most branching, least verification, DST-unsafe arithmetic. The parser at 66% means roughly a third of the grammar's error paths are unexercised.

Also: **no CI**, so nothing runs this suite except a human remembering to; **20 `Process.sleep` calls** in tests as wall-clock timing assertions, with the flake tax already visible in the history (`chore: ... widen dwell-test timing window`); and test logging is not silenced, so a full run prints hundreds of `[info]` lines that drown real failures.

### 4.9 Code smells — ADEQUATE

Genuinely clean in ways most codebases are not: **zero `TODO`/`FIXME`/`XXX`/`HACK` comments** in `lib/` or `test/` (verified by grep), no commented-out code, no compiler warnings even under `--warnings-as-errors`, and comments that explain *why* rather than *what*.

Against that: the process-dictionary evaluator (§4.3) is the largest smell in the tree and it is load-bearing; `mix format --check-formatted` fails on `parser.ex` (a hand-aligned `@precedence` table edited past the formatter); `cond` is used as a variable name, shadowing the special form; `handle_call({:load, ...})` is 81 lines doing five unrelated jobs, its first 30 lines near-verbatim duplicates of `init/1`.

### 4.10 Naming — ADEQUATE

No misspellings in public API names — a clean sweep, which is unusual. Conventions are consistent throughout.

Issues: **`transclude` vs `transduce`** — `Anemos.DataModel` declares a `transduce/3` callback while the same module's moduledoc says "transclude," and `CompiledData`, `AST.DataDecl`, `DataStore`, and the lexer all use `transclude`. A reader cannot tell whether these are one concept or two. **`TripleStore`'s moduledoc documents a function that does not exist** (`assert/4`; the real one is `assert_triple/4`) — copy the example, get an `UndefinedFunctionError`. **`{:set_connector, _}` has no documented client function**, reached only by a raw `GenServer.call` from `Runtime.connect/2`.

### 4.11 Documentation — GOOD, with a specific rot problem

The strongest area by a wide margin. The 514-line README is accurate and could ship. `@moduledoc` on every public module. `ISSUES.md` is exemplary — three issues, each with symptom, verbatim grep evidence, file/line citations, "why it happens," and "what should change"; all three were independently confirmed by multiple analysts. `docs/superpowers/specs/` and `docs/plans/` carry dated design specs per feature and the git history shows the discipline being followed.

The rot is concentrated in status documents, and it points the wrong way:

| Document | Claim | Verdict |
|---|---|---|
| `README.md` "Project Status" | loops, flow control, guards, pipelines, NLD, triples all work | **accurate** |
| `TODO.md` | those same four listed under "Not implemented (15%)" | **stale and misleading** |
| `● Here's where we stand against the spec.md` | same, different ordering | **stale, untracked, delete** |

All four features are implemented, tested (`loop_test.exs`, `flow_control_test.exs`, `guard_test.exs`, `pipeline_test.exs`), and marked done in the git history. A newcomer reading `TODO.md` will substantially *underestimate* the system. Two contradicting status documents, neither matching the code, is worse than none.

The README also **links to nothing** — zero references to `docs/`, `design-notes`, `ISSUES.md`, or `TODO.md`. Eight design documents and a three-issue tracker are undiscoverable from the entry point. And ExDoc publishes both dead modules as live API, indistinguishable from working ones.

### 4.12 Repository hygiene

- `erl_crash.dump` — 5.9 MB, gitignored, not tracked. Delete.
- `doc/` — 90+ generated ExDoc files in the working tree, gitignored.
- `mix.lock` — tracked *and* gitignored. Reconcile.
- Three `.tcl` design sketches tracked **twice**, at repo root and under `docs/design-notes/sketches/`; the root copy of `stop-data-extraction-policy.tcl` is diverging. Two of them are also marked `0755` despite having no shebang.
- `● Here's where we stand against the spec.md` — untracked, leading U+25CF, a pasted terminal transcript. Delete.
- `.gitignore` does not cover `.elixir_ls/` or `.codegraph/`.

---

## 5. Usability and Developer Experience

### 5.1 What works

The **language design is good**. Three top-level declarations (`rule`, `condition`, `capability`), regular nesting, a coherent sigil model, and a statement vocabulary that reads well. The **runtime API is well-judged** — blank interpreter, everything loads dynamically, declarations accumulate. The **`Anemos.Module` extension point is close to ideal**. `notebooks/playground.livemd` (488 lines) is the best learning artifact in the repository.

### 5.2 The dominant defect: silent `nil` for every unbound variable

```text
[let a = 42, read with @a]  => {:ok, [%{type: :log, value: 42}]}
[let a = 42, read with $a]  => {:ok, [%{type: :log, value: nil}]}
[log @nosuchvar]            => {:ok, [%{type: :log, value: nil}]}
```

`Map.get/2` with no default. Wrong sigil, typo, or genuinely absent context data all resolve to `nil`, log an empty line, and report success. There is no distinction between "you meant a different sigil" and "the environment did not supply this."

**A shipped example has this bug.** `priv/examples/normalize-pdfs.rule:9-12` binds `let title = ...` (creating `@title`) and then compares `if $title ne $meta_title`. Both are `nil`, `nil ne nil` is false, and the branch is dead. Nobody noticed because nothing complained.

### 5.3 Two of the three shipped examples do not work

| Example | Result |
|---|---|
| `garage-lights.rule` | Works |
| `normalize-pdfs.rule` | `No rules matched event FILE_CREATED.` |
| `ddns.rule` | 2 of 4 operations fail |

`normalize-pdfs.rule` fails twice over: its outer guard compares against the `FILE` stub's echo map, which never equals `"pdf"`, and the inner body is dead per §5.2. `ddns.rule` references an `INFRA` module that is not among the two registered defaults. It also demonstrates an interpolation gap: `as ddns.update.:{?fqdn}` renders literally — the `:{...}` form appears in the README, both examples, and the parser, and produces no substitution and no error.

`TODO.md` claims all three "parse and run."

### 5.4 Failures are reported as success

```text
$ mix anemos.run priv/examples/ddns.rule --event CONDITION_networkchanged
Dispatched CONDITION_networkchanged -- 4 operation(s):
  emit %{...}
  {:error, %Comn.Errors.ErrorStruct{message: "Module INFRA not found in registry", ...}}
  {:error, %Comn.Errors.ErrorStruct{...}}
  emit %{...}
$ echo $?
0
```

Exit code 0 despite two hard failures — the CLI cannot be used in a script or CI gate. Raw struct inspection reaches the terminal including `request_id`/`trace_id`/`correlation_id`. Errors are counted as "operations."

Related: **"No rules matched" is factually wrong.** `{:ok, []}` means zero *operations*, not zero *rules matched*. Three genuinely distinct states — no rule subscribed; a rule ran but every branch was false; a rule ran and all operations failed — collapse into one message that sends the user to inspect the one thing that was correct.

### 5.5 Parser diagnostics contradict the project's own stated principle

`docs/design-notes/language-ergonomics.md` principle 6: *"Error messages should suggest corrections. Users should safely guess syntax."*

Measured against 14 malformed inputs:

| Input | Message |
|---|---|
| Missing closing brace | `Unexpected end of input, expected statement` |
| Typo `whne` for `when` | `Unexpected token identifier on line 2, expected statement` |
| `for 10 min` (space in duration) | `Expected lbrace but got keyword on line 2` |
| Empty file | **parses OK** |

Six failures against principle 6: internal token names leak (`lbrace`, `rbrace`, `keyword`, `operator` — a policy author has never seen these); the offending token's *value* is never shown; **no column, contradicting `CLAUDE.md`'s stated convention** — the lexer computes a column and the parser discards it at `parser.ex:61`; no source excerpt or caret; the most common beginner error (unbalanced brace) gets the worst message, with no line number at all; and no suggestions, ever.

The `ErrorStruct` carries a `suggestion:` field. It is `nil` in every error the system produces — and the unknown-module and unknown-verb errors have the full registry in hand at the moment of failure.

### 5.6 There is essentially no compile-time checking

The entire compiler has **one** diagnostic: `"for <duration>: zero duration not allowed"`. Not checked: unknown modules, unknown verbs, unknown capabilities, undefined variables, sigil/keyword mismatches, duplicate declaration names, nonexistent `nextrule` targets. A policy file can be entirely wrong and compile cleanly.

Duplicate declarations silently coexist and both fire, with no warning — and since `load/2` accumulates, loading the same file twice doubles every rule in it (§4.5).

### 5.7 Other friction

- **Nobody outside this machine can build the project** (§1.9). No installation section explains that a sibling `comn` checkout is required.
- **Two ways to write a context block**, used inconsistently across the examples and within the README itself, with nothing explaining when to use which.
- **A mistyped filename produces a five-frame Elixir stacktrace** — `File.read!` at `anemos.run.ex:21` has no guard. There is no `--help`, no `--check`/parse-only mode, and no `--context` flag, which means every context-scoped rule in the examples is untestable from the CLI.
- **No hot reload**, and no way to unload a policy or unregister a module. Correcting a mistake requires restarting the runtime and losing all state.
- **No i18n** — a defensible choice for a developer DSL, but error strings are built inline at ~60 sites in the parser alone, so there is no central place to improve message quality.

### 5.8 The summary judgement

The system is built to keep going: unbound variables become `nil`, failed commands are recorded and execution continues, errors ride home inside `{:ok, ...}`, and the process exits 0. That is a reasonable posture for a long-running policy engine that must not die on one bad rule. **It is the wrong posture for the authoring loop, and Anemos currently applies it to both.** The result is a language that will not tell you when you are wrong.

---

## 6. Roadmap for Improvements

Effort estimates assume one engineer familiar with Elixir/OTP. They cover implementation plus regression tests, not design review.

### Phase 0 — Stop the Bleeding

*Crash, data-loss, and silent-incorrect-execution fixes. Nothing else matters until these are done. Do not run this unattended before Phase 0 completes.*

| # | Item | Addresses | Effort |
|---|---|---|---|
| 0.1 | **Fix the supervision tree.** Move `ConditionServer`, `CapabilityServer`, `TripleStore`, `DataStore`, `SubscribableRegistry` under a real supervisor — `RuleSupervisor` is already written for this. Make the dispatcher trap exits, or better, stop it owning process lifecycles. Persist loaded policies outside dispatcher state so a restart does not zero the system. Add `rescue` around the `ConditionServer` evaluator. *Test: kill each child, assert policies still fire.* | §4.1 | 1–2 weeks |
| 0.2 | **Bound event recursion.** Thread a depth counter or visited-event set through `dispatch_to_rules/3`, with a configurable ceiling and a structured error on breach. Apply to `nextevent`, `nextrule`, and `emit`-label re-dispatch alike. *Test: the two-rule cycle must terminate with an error.* | §4.2 | 2–3 days |
| 0.3 | **Remove the process-dictionary evaluator.** Thread the accumulator through the throw payload — `throw({:anemos_return, ops, bindings})` already carries ops, so the dictionary is redundant on that path; the reduce accumulator just needs to be reachable, which `reduce_while` gives you. Minimum viable fix if the rewrite is deferred: wrap `build_handler`'s body in `try/after` restoring the key. *Test: the three-rule leak.* | §4.3 | 3–5 days (1 day for the stopgap) |
| 0.4 | **Compile condition trigger expressions.** Replace the hardcoded `fn _, _ -> true end` with a real evaluator, and stop discarding condition-body operations. | §4.4 | 3–5 days |
| 0.5 | **Fix context boundary matching** — segment-aware comparison, and default-deny when a rule declares a context and the event supplies none. *Test: `"garage"` must not match `"garageband.studio"`.* | §3.4 | 1 day |
| 0.6 | **Stop interning unmatched identifiers as atoms** in `lexer.ex:504`; `String.to_existing_atom/1` with rescue at the five closed-set sites. | §3.6 | Hours |
| 0.7 | **Make unknown capabilities fatal** in `Demand.handle_missing/6` regardless of flag. | §3.9 M-1 | Minutes |
| 0.8 | **Clamp scheduler intervals** to a minimum, cap schedules per runtime, add a `Duration.to_ms/1` catch-all. Cancel the old timer when an event name is reused. | §2.5, §3.9 M-2 | 1 day |

### Phase 1 — Security Hardening

*Do these before exposing `load/2` to anything but a trusted operator, and before wiring a real `FILE`, `INFRA`, or `SECRET` module.*

| # | Item | Addresses | Effort |
|---|---|---|---|
| 1.0 | **Decide what Anemos is** — trusted-operator engine or multi-tenant policy engine (§3.11). Everything below depends on this answer. | — | Design decision |
| 1.1 | **Add `[:safe]`** to the three `binary_to_term/1` calls in `comn`'s SQLite queue. Raise against that repo directly. | §3.9 M-4 | Minutes |
| 1.2 | **Introduce a redacting secret wrapper type** with a custom `Inspect`; stop `inspect`ing payloads in `Channel.Logger` and in error paths; return a correlation id plus a stable code instead of `Exception.message/1`. | §3.7, §3.9 M-3 | 3–5 days |
| 1.3 | **Enforce capability context** — pass the demanding rule's context into `CapabilityServer.execute/2` and reject on mismatch inside the server. | §3.5 | 3–5 days |
| 1.4 | **Resolve `signed_by`** — implement verification before `load/2` installs the rule, or remove the keyword and the `Envelope.signature` field. Do not ship a parsed-but-ignored security attribute. | §3.3 | Days to implement, minutes to remove |
| 1.5 | **Add an `arg_schema/1` callback** to `Anemos.Runtime.Module`, enforced by the dispatcher before `handle_verb/3`. Confine every path-taking verb to a configured root. | §3.2 | 2–3 weeks |
| 1.6 | **Gate `load/2`** behind an explicit privileged path; remove `:load` from the `Comn.act/1` surface. | §3.1 | 3–5 days |
| 1.7 | **Make `ModuleRegistry.register/3` write-once** or require explicit replacement; log every registration at `:warning`. | §3.8 | Hours |
| 1.8 | **In `comn`:** default NATS to TLS and plumb NKey/JWT credentials; replace SHA-256 key derivation with HKDF-SHA256 and separate signing from encryption keys. | §3.9 M-5, M-6 | 1 week |
| 1.9 | Delete `erl_crash.dump`; remove `mix.lock` from `.gitignore`; drop the executable bit from the `.tcl` sketches. | §3.9 M-7, M-8 | Minutes |

### Phase 2 — Stabilization

*Tests, CI, and the state-integrity bugs that are not silent-corruption class.*

| # | Item | Addresses | Effort |
|---|---|---|---|
| 2.1 | **Add CI:** `mix format --check-formatted`, `mix test`, `mix test --cover` with an explicit threshold. Half a day of work that would have caught two items in this report. | §1.9, §4.8 | 0.5 day |
| 2.2 | **Propagate state out of nested dispatch** — stop discarding `_state` in `:nextevent` and `_new_persistent` in `:nextrule`; deliver `nextrule` args. | §4.5 | 2–3 days |
| 2.3 | **Give `Dispatcher.load/2` replace-or-reject semantics** on duplicate rule names; add unload/reload; same for `Scheduler.schedule/2` plus timer cancellation. Stop orphaning condition servers on reload. | §4.5 | 1 week |
| 2.4 | **Separate dwell state from `set` bindings** — different lifetimes deserve different namespaces; key dwell state by `(rule, when-block)` rather than rule name. | §4.5, §2.6 | 3–5 days |
| 2.5 | **Make `load/2` return its results** and `dispatch/3` return `{:error, _}` when the operation list contains errors. Unify the three error representations on the `Comn` registry. | §4.6 | 3–5 days |
| 2.6 | **Fix `Anemos.run/2`'s process leak** — stop the linked children explicitly. | §4.5 | Hours |
| 2.7 | **Raise Scheduler coverage from 20%**, and replace `NaiveDateTime.local_now/0` with DST-aware arithmetic. Implement recurrence for specs other than `{:time, {h,m}}`. | §2.5, §4.8 | 1 week |
| 2.8 | **Replace `TripleStore`'s list with a `MapSet`** and decide a retention policy. Fix `DataStore`'s scope-discriminator inconsistency so cleanup is reachable. | §4.5 | 3–5 days |
| 2.9 | Add `dialyxir` and `credo`; define an `@type operation ::` union so compiler and dispatcher agree by contract rather than by moduledoc. Silence Logger in `config/test.exs` (and add the missing `import_config/1`). Replace `Process.sleep` timing assertions with message-based synchronization. | §1.8, §4.7, §4.8 | 1 week |
| 2.10 | **Resolve the `comn` dependency** into something other machines can fetch — a git ref at minimum, a published package ideally. | §1.9 | 1–3 days |

### Phase 3 — Architecture Simplification

*These pay down the root cause rather than its symptoms.*

| # | Item | Addresses | Effort |
|---|---|---|---|
| 3.1 | **Split effect execution out of the dispatcher.** Run `execute_op` in a supervised `Task` with an explicit timeout; move `rule_bindings`, `TripleStore`, and `DataStore` under the `Runtime` supervisor rather than under the dispatcher. This closes §4.1, §4.2, §4.3, verb-blocking, and most of the dwell collisions **at once**. Nothing else needs to change first. | §5.1 below | 2–4 weeks |
| 3.2 | **Replace the cast/call/receive barrier** with one `GenServer.call` per condition, and stop silently discarding out-of-cycle transitions. | §1.5 | 1 week |
| 3.3 | **Adopt `Registry`** for process addressing instead of dynamically constructed atoms. | §1.8 | 3–5 days |
| 3.4 | **Add a status API** — what rules are loaded, which conditions are true, which dwell timers are armed, what schedules are pending. Every probe in this analysis had to reach into `:sys.get_state/1`. | §6.3 below | 1 week |
| 3.5 | **Delete or wire in the dead code** — `RuleSupervisor` (wire it, per 0.1), `DataModelRegistry` (delete), the two dead `execute_op` clauses, the empty `Anemos.Application` child list, `DataStore.deregister/3`, `SubscribableRegistry.list/1`. | §1.3, §2.3 | 1–2 days |
| 3.6 | Move the four `Compiled*` structs out of `compiler.ex` into their own files; extract the duplicated server-construction block shared by `init/1` and `handle_call({:load, ...})`; run the formatter on `parser.ex`. | §4.9 | 1–2 days |

### Phase 4 — Feature Completeness and Developer Experience

| # | Item | Addresses | Effort |
|---|---|---|---|
| 4.1 | **Make unbound variables loud.** Distinguish "not bound" from "bound to nil" in `resolve_expr` and surface the former as a diagnostic. This alone would have caught the bug in the shipped `normalize-pdfs.rule`. | §5.2 | 3–5 days |
| 4.2 | **Add a semantic validation pass** between compile and load: unknown modules, verbs, capabilities, `nextrule` targets, sigil/keyword mismatches, duplicate names. All are checkable with information already in hand. | §5.6 | 1–2 weeks |
| 4.3 | **Centralize diagnostics.** Thread the lexer's already-computed column through token metadata, add a source excerpt with a caret, translate token atoms to user-facing names, populate `suggestion:`. One `Anemos.Diagnostics` module fixes ~60 scattered interpolation sites and makes the project's own principle 6 achievable. | §5.5 | 1–2 weeks |
| 4.4 | **Fix the two broken examples**; implement or remove the `:{...}` interpolation form. These are what a newcomer meets first. | §5.3 | 2–3 days |
| 4.5 | **Rewrite or delete `TODO.md`**; delete `● Here's where we stand against the spec.md`; de-duplicate the three root `.tcl` sketches; link the README to `docs/`, `ISSUES.md`, and the Livebook. | §4.11, §4.12 | 0.5 day |
| 4.6 | **Improve the CLI**: `OptionParser`, `--help`, `--check`, `--context`, a guard on `File.read!`, and a non-zero exit code when the result list contains errors. | §5.4, §5.7 | 2–3 days |
| 4.7 | **Wire or remove `Anemos.DataModel` and query blocks.** Both parse, both compile, neither executes — `data { edn { ... } }` is accepted and silently ignored, and `CompiledQuery` handlers merely echo their inputs. Also: piped `emit` builds command ops and discards them; subscription refs are discarded with no unsubscribe path; `periodic` is parsed and unimplemented. | §1.4 | 2–3 weeks, or 1 day to remove |
| 4.8 | Bound `for` loops; make `while`'s 10,000-iteration truncation loud. Cache compiled regexes rather than `Regex.compile!` per evaluation. | §4.2 | 2–3 days |
| 4.9 | Settle `transclude` vs `transduce`; fix `TripleStore`'s moduledoc example; give `{:set_connector, _}` a documented client function; mark `Runtime.Builtins` `@moduledoc false`. | §4.10 | 0.5 day |

---

## 7. The two decisions that matter

Everything above reduces to two items. They are worth stating separately because the roadmap is long and these are what actually determine the outcome.

**7.1 — One structural cause.** The dispatcher is simultaneously the router, the interpreter, the effect executor, and the owner of all mutable state, in one unsupervised process. That single decision produces the process-dictionary contamination (one dictionary shared by all rules), the wedging (host code runs in the router's `handle_call`), the total policy loss on crash (state lives in the process that runs untrusted closures), the binding collisions (one flat map keyed by rule name), and the recursion hazards (re-entrant calls into `dispatch_to_rules` from within a dispatch). Item 3.1 addresses the cause; items 0.1–0.4 address the symptoms and are still worth doing first because they are far cheaper and the system should not run unattended in the meantime.

`RuleSupervisor` sitting unwired since v0.1.0 is the tell: the right design was identified and never built.

**7.2 — One unmade product decision.** Trusted-operator engine, or multi-tenant policy engine (§3.11)? The codebase currently has the security vocabulary of the second and the trust assumptions of the first. Until that is settled, Phase 1 cannot be scoped — half of it is unnecessary under one answer and insufficient under the other. The parsed-but-ignored `signed_by` keyword is the clearest symptom and the one most likely to mislead an operator into trusting a rule file they should not.

---

## Appendix A — Contradictions found between project documents and code

Recorded because they will mislead the next reader.

| Claim | Source | Reality |
|---|---|---|
| Loops, flow control, guards, pipelines "not implemented" | `TODO.md` | All four implemented, tested, documented in README |
| "All three example files parse and run" | `TODO.md` | Two of three do not work (§5.3) |
| Compiler produces "executable rule modules" | `CLAUDE.md` | Closures only; no code generation (§1.1) — the code is *safer* than the doc |
| "Parser errors include line/col position" | `CLAUDE.md` | Column computed by lexer, discarded by parser (§5.5) |
| `put_context/3` supplies `?` values | `README.md` | `ContextStore` is never read by the dispatch path (§2.4) |
| `context` is "an exclusionary boundary" | `README.md` | Fails open on unscoped events; unanchored prefix match (§3.4) |
| `DataStore` scope is `{:local, pid}` | moduledoc | Live callers pass `{:local, String.t()}` (§4.5) |
| `TripleStore.assert(store, s, p, o)` | moduledoc | Function is `assert_triple/4`; the example raises |
| License "AGPL-3.0" | `README.md` | `mix.exs` says AGPL-3.0-or-later |
| Unexpected exceptions "left to crash" | `dispatcher.ex:465` comment | A bare `catch kind, reason` below it catches throws and exits |

`ISSUES.md` and the four `arch/diagrams/*.c4` files are the exceptions: both were spot-checked against the code and found accurate, including their honest annotations that `DataModelRegistry` and `RuleSupervisor` are present but never started.

## Appendix B — Open questions the code did not settle

- **`safe_handle/4`'s intended exception policy.** The comment and the code disagree; which is intended is not determinable from source.
- **Whether `DataStore` pid-scoping is a planned path or abandoned.** The monitor code exists and is unreachable.
- **`Anemos.AST.Flow`, `.On`, `.It`, `.BlockArgs`** are defined, documented, and never constructed by the parser. Placeholders for unimplemented spec sections, or leftovers? `BlockArgs` is *read* in the compiler for `NextRule` args, but the parser always sets those to `nil`, so the branch is unreachable.
- **Whether unscoped events matching every rule is intended.** It is the default path, which argues for intent; it also voids the documented boundary, which argues against.
- **The language specification is not in this repository.** `docs/design-notes/` points to an Obsidian vault outside the tree. Conformance claims in `TODO.md` and the README reference spec section numbers that cannot be checked against anything in-tree — which is also why the "% complete" figures in those documents could not be independently assessed.

## Appendix C — Individual analysis reports

| Report | Scope |
|---|---|
| [architecture.md](architecture.md) | System overview, component inventory, protocols, dependencies, build, concurrency model |
| [security.md](security.md) | 25 findings rated CRITICAL→INFORMATIONAL, prioritized remediation table |
| [data-processing.md](data-processing.md) | Data flows, process lifecycle, state transitions; 8 defects reproduced against a live runtime |
| [usability.md](usability.md) | Language ergonomics, diagnostics quality, examples, documentation discoverability |
| [quality.md](quality.md) | 12 graded areas, coverage measurement, 4 defects reproduced, prioritized fix list |

## Appendix D — Method and limits

All 39 files in `lib/` were read in full by at least two analysts. `mix.exs`, `mix.lock`, all three `config/*.exs`, `.gitignore`, `.formatter.exs`, the four `arch/diagrams/*.c4`, the three `priv/examples/*.rule`, `README.md`, `TODO.md`, `ISSUES.md`, and `CLAUDE.md` were read in full. The `comn` path dependency was reviewed only at Anemos's call sites into it — **it was not audited in full**, and findings M-4, M-5, M-6 and part of §3.2 live in that codebase and should be re-raised against it directly.

The test suite was executed (`mix test`, exit 0) and coverage measured. Twelve defect hypotheses were tested empirically against a live runtime by two analysts working independently; those are the **[REPRODUCED]** findings. Probe files were written under the analysts' scratch space and removed — `git status` was verified clean of them before this report was written.

Not performed: dynamic analysis, fuzzing, CVE scanning against a live advisory database (`mix hex.audit` is recommended and was outside this pass), review of `test/` beyond scope sampling, and review of the generated `doc/` output.

One analyst disagreement was recorded and resolved on evidence (§4.3). One test-count discrepancy across reports (403 vs 432) was resolved to 403 by re-measurement. This audit reflects the working tree, which had uncommitted modifications to `mix.lock` and `stop-data-extraction-policy.tcl`, not a clean checkout of `80ba1b4`.

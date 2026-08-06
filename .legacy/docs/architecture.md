# Anemos — As-Built Architecture Analysis

**Repository:** `/home/imsmith/github/anemos`
**Analysis date:** 2026-08-06
**Commit at time of analysis:** `80ba1b4` (main, 128 commits, no other branches)
**Working tree state:** dirty — `mix.lock` and `stop-data-extraction-policy.tcl` modified; one untracked file with a corrupted name (`● Here's where we stand against the spec.md`)

This document records what the code does, not what the README says it does. Where
the two diverge, both are stated. Where the code is ambiguous, that is called out
rather than resolved by assumption.

---

## 1. System Overview

Anemos is an **Elixir library**, not a service. It implements a domain-specific
language for event-driven automation policy and a supervisable in-process
interpreter for that language.

| Property | Value | Source |
|---|---|---|
| OTP application | `:anemos` | `mix.exs:8` |
| Version | `0.1.0` | `mix.exs:9` |
| Elixir requirement | `~> 1.19` | `mix.exs:10` |
| Application callback module | `Anemos.Application` | `mix.exs:31` |
| License | AGPL-3.0-or-later | `mix.exs:22` |
| Source size | 6,455 lines across 39 `.ex` files in `lib/` | measured |
| Test size | 6,577 lines across 38 files in `test/` | measured |
| Test result | 20 doctests, 403 tests, 0 failures (3.4s) | `mix test`, run 2026-08-06 |

### What it actually does

The pipeline is four stages, all in-process, all synchronous:

```text
.rule source
    │
    ▼  Anemos.Lexer.tokenize/1        (NimbleParsec combinators → flat token list)
tokens
    │
    ▼  Anemos.Parser.parse/1          (hand-written recursive descent + precedence climbing)
%Anemos.AST.Program{}
    │
    ▼  Anemos.Compiler.compile/1      (AST walk → Elixir closures; NO code generation)
%Anemos.CompilationResult{rules, conditions, capabilities, schedules, data_blocks, query_blocks}
    │
    ▼  Anemos.Runtime.Dispatcher      (GenServer; event name → rule index → run closure → execute ops)
list of {:ok, op} | {:error, reason}
```

The compiler explicitly does **not** generate modules. `lib/anemos/compiler.ex:81`
states "No code generation, no `Module.create`." Rules become anonymous functions of
arity 3 — `(event_name, context, persistent_bindings) -> {:ok, [operation], bindings}` —
held in a `%Anemos.CompiledRule{}` struct. Every "compiled rule" is a closure over AST
fragments that are re-interpreted on each firing. The system is therefore an
**AST-walking interpreter wearing a compiler's naming**, and its per-event cost is
proportional to statement count, not amortised.

### Three entry points

1. **`Anemos.run/2`** (`lib/anemos.ex:38`) — one-shot. Parses, compiles, starts a
   throwaway `ModuleRegistry` and `Dispatcher`, registers the two stub modules,
   dispatches one event, then stops both processes in `after` blocks. Suitable for
   scripts and tests only.
2. **`Anemos.Runtime`** (`lib/anemos/runtime.ex`) — the supported integration path.
   A `Supervisor` the host application starts in its own tree; policies and modules
   are loaded into it at runtime.
3. **`mix anemos.run FILE --event EVENT`** (`lib/mix/tasks/anemos.run.ex`) — thin CLI
   wrapper over `Anemos.run/2`.

---

## 2. Component Inventory

### 2.1 Language frontend (`lib/anemos/`)

| Module | Lines | Role | Depends on |
|---|---:|---|---|
| `Anemos.Lexer` | 554 | NimbleParsec tokenizer. Emits `{type, [line: n], value}` tuples. | `NimbleParsec` |
| `Anemos.Parser` | 1,946 | Recursive-descent parser. 14-level precedence-climbing expression parser. | `Anemos.Lexer`, `Anemos.AST` |
| `Anemos.AST` | 258 | 28 plain structs, one nested `defmodule` each. All carry `:line`. | none |
| `Anemos.Compiler` | 911 | AST → closures. Also defines `CompiledRule`, `CompiledData`, `CompiledQuery`, `CompilationResult` in the same file. | `Anemos.AST`, `Runtime.Duration`, `Runtime.Builtins`, `Runtime.DataStore` |

`Anemos.Parser` at 1,946 lines is the single largest module and the one with the most
concentrated risk. It is a flat list of `defp parse_*` clauses matched on token-list
head patterns. There is no grammar artefact; the grammar exists only as pattern-match
order.

### 2.2 Compiled-form structs

| Struct | Defined in | Enforced keys |
|---|---|---|
| `Anemos.CompiledRule` | `compiler.ex:1` | `name`, `subscriptions`, `handler` |
| `Anemos.CompiledData` | `compiler.ex:25` | `name` |
| `Anemos.CompiledQuery` | `compiler.ex:42` | `name` |
| `Anemos.CompilationResult` | `compiler.ex:58` | none (all default `[]`) |
| `Anemos.CompiledCondition` | `compiled_condition.ex` | `name`, `subscriptions`, `evaluator` |
| `Anemos.CompiledCapability` | `compiled_capability.ex` | `name`, `context`, `handler` |
| `Anemos.CompiledSchedule` | `compiled_schedule.ex` | `event_name`, `time_spec` |

Note the inconsistency: four compiled structs live inside `compiler.ex`; three live in
their own files. There is no stated reason for the split.

### 2.3 Runtime (`lib/anemos/runtime/`)

| Module | Lines | Process type | Started by |
|---|---:|---|---|
| `Anemos.Runtime` | 218 | `Supervisor` (`:one_for_one`) | host application |
| `Anemos.Runtime.Dispatcher` | 664 | `GenServer` | `Runtime` supervisor |
| `Anemos.Runtime.Scheduler` | 222 | `GenServer` | `Runtime` supervisor |
| `Anemos.Runtime.ModuleRegistry` | 72 | `Agent` | `Runtime` supervisor |
| `Anemos.Runtime.ContextStore` | 58 | `Agent` | `Runtime` supervisor |
| `Anemos.Runtime.ConditionServer` | 85 | `GenServer`, one per condition | `Dispatcher.init/1` and `handle_call({:load, …})` |
| `Anemos.Runtime.CapabilityServer` | 60 | `GenServer`, one per capability | same |
| `Anemos.Runtime.TripleStore` | 128 | `Agent` | `Dispatcher.init/1` |
| `Anemos.Runtime.DataStore` | 233 | `GenServer` | `Dispatcher.init/1` |
| `Anemos.Runtime.SubscribableRegistry` | 75 | `Agent` | `Dispatcher.init/1` |
| `Anemos.Runtime.DataModelRegistry` | 76 | `Agent` | **nothing — never started** |
| `Anemos.Runtime.RuleSupervisor` | 27 | `DynamicSupervisor` | **nothing — never started** |
| `Anemos.Runtime.Demand` | 81 | pure module | called from `Dispatcher` |
| `Anemos.Runtime.Builtins` | 56 | pure module | called from compiled closures |
| `Anemos.Runtime.Duration` | 30 | pure module | `Compiler`, `Scheduler` |
| `Anemos.Runtime.NLD` | 118 | pure module | `Scheduler` |
| `Anemos.Runtime.Errors` | 20 | compile-time registry | `Application.start/2` |
| `Anemos.Runtime.Module` | 10 | behaviour | — |

`DataModelRegistry` and `RuleSupervisor` are dead code. Both are already filed in the
repository's own `ISSUES.md` (entries dated 2026-08-04) and both are still published to
`doc/` as live API pages. `RuleSupervisor` has exactly one reference in the entire tree:
its own `defmodule` line.

### 2.4 Extension points

| Module | Kind | Purpose | Live consumer? |
|---|---|---|---|
| `Anemos.Runtime.Module` | behaviour | `handle_verb/3` — backs `[MODULE::verb …]` | yes — `Dispatcher.execute_op/3` |
| `Anemos.Module` | macro | `use Anemos.Module, name: "X"` + `verb :y, fun` | yes — the two stubs |
| `Anemos.Event` | protocol | `name/1`, `context/1`, `payload/1` | yes — `Runtime.dispatch/3` |
| `Anemos.Channel` | behaviour | `publish/2` for `emit … to channel(…)` | yes — `Dispatcher.execute_op/3` |
| `Anemos.Subscribable` | behaviour | `subscribe/3`, `unsubscribe/1`, `periodic?/0`, `interval/1` | yes — `Dispatcher.handle_call({:load, …})` |
| `Anemos.DataModel` | behaviour | `keyword/0`, `parse/1`, `eval/2`, `transduce/3` | **no** — nothing calls any of the four callbacks |

`Anemos.DataModel` is a declared but unwired extension point. Its only registry
(`DataModelRegistry`) is never started, and no runtime code path invokes `parse/1`,
`eval/2`, or `transduce/3`. The `query` language construct parses and compiles but
never executes (see §5.4).

### 2.5 Built-in module implementations

`Anemos.Runtime.Modules.Device` (`DEVICE`, verbs `set`/`get`) and
`Anemos.Runtime.Modules.File` (`FILE`, verbs `read`/`write`/`rename`/`extension`).
Both are explicitly stubs — every verb echoes its arguments back as
`%{module: …, verb: …, args: …}`. No file I/O, no device I/O. The README states this
("Module backends are stubs — bring your own implementations") and the code confirms it.

---

## 3. Backend Architecture

**There is no backend server.** No HTTP listener, no router, no middleware chain, no
RPC framework, no socket. `grep` finds no Plug, Phoenix, Cowboy, Bandit, or `gen_tcp`
usage anywhere in `lib/`. The Hex dependency list is `nimble_parsec` plus a path
dependency and a dev-only doc generator.

What stands in for "request flow" is the dispatch cycle, which is worth documenting in
full because it is the system's only control flow of consequence.

### 3.1 The dispatch cycle

`Anemos.Runtime.Dispatcher.handle_call({:dispatch, event_name, context}, …)`
(`dispatcher.ex:147`) executes the following, entirely inside the dispatcher process:

1. **Build a Comn context.** A `Comn.Contexts.ContextStruct` is constructed with a
   `request_id` (random 8 bytes, hex32-encoded, generated if absent), `parent_event_id`
   set to the event name, plus `correlation_id`, `trace_id`, `actor`, and a metadata map
   carrying `context_path` (`dispatcher.ex:341-356`). The whole cycle runs inside
   `Comn.Contexts.with_context/2`, which stores the struct in the **process dictionary**
   and restores the previous value afterwards.
2. **Fan out to condition servers.** Every `ConditionServer` receives an async
   `GenServer.cast`.
3. **Barrier.** Every `ConditionServer` is then hit with a synchronous
   `get_state` call, purely to force the casts to drain
   (`dispatcher.ex:158-161`). This is an explicit serialisation point; cost is O(number
   of conditions) round-trips per event, regardless of relevance.
4. **Drain transitions.** `collect_transitions/0` does a non-blocking `receive` loop over
   the dispatcher's own mailbox for `{:condition_transition, name}` messages placed there
   by condition-server callbacks.
5. **Dispatch to rules.** `dispatch_to_rules/3` looks the event name up in `state.index`
   (a plain map, event name → list of rules), filters by context, then either runs the
   handler immediately or feeds the dwell state machine.
6. **Dispatch synthetic condition events.** Each drained transition becomes a
   `"CONDITION_<name>"` event dispatched through the same path.

### 3.2 Rule execution and operation dispatch

`dispatch_immediate/5` (`dispatcher.ex:401`):

- Loads that rule's persistent bindings from `state.rule_bindings[rule.name]`.
- Enriches the context with `:data_store` (the DataStore pid) and `:_rule_name`, so the
  compiled closure can resolve `memberof()`. This is a deliberate replacement of an
  earlier process-dictionary approach (commit `7a0410b`).
- Calls the handler inside `safe_handle/4`, which rescues eight named exception types
  (`RuntimeError`, `ArgumentError`, `FunctionClauseError`, `MatchError`, `BadMapError`,
  `KeyError`, `UndefinedFunctionError`, `ArithmeticError`) plus a bare `catch kind, reason`.
  The comment at `dispatcher.ex:465-466` claims unexpected exception types are "left to
  crash and restart via the supervisor" — but the `catch kind, reason` clause at
  `dispatcher.ex:478-479` catches throws and exits generically, so the stated policy and
  the code do not fully agree.
- Writes the returned persistent bindings back, then executes each operation.

Operation types handled by `execute_op/3`: `:command`, `:log`, `:emit`, `:demand`,
`:assert_triple`, `:triple_query`, `:nextevent`, `:nextrule`, `:register_data`,
`:register_query`. The `recon/0` introspection map at `dispatcher.ex:367` lists only
eight of these — `:register_data` and `:register_query` are omitted.

### 3.3 Emit re-dispatch — unbounded recursion

`execute_op` for `:emit` (`dispatcher.ex:504`) does two things: publishes an
`%Anemos.Envelope{}` to the channel connector if the destination is `{:channel, path}`,
and — if the emit carries a string `label` — returns `{:emit_event, label, op}`. The
caller then calls `dispatch_to_rules/3` recursively with the label as the event name
(`dispatcher.ex:429-432`).

**There is no cycle detection and no depth limit.** A policy in which rule A emits a
label that rule B subscribes to, and rule B emits a label A subscribes to, will recurse
until the dispatcher process exhausts its stack or the BEAM's process heap limit. The
`while` loop has an explicit 10,000-iteration cap (`compiler.ex:636`); the emit
re-dispatch path has no equivalent. This is the most significant liveness risk in the
codebase for adversarial or merely careless policy input.

### 3.4 `nextrule` / `nextevent` state loss

`execute_op` for `:nextevent` (`dispatcher.ex:557`) calls
`dispatch_to_rules(target, context, state)` and **discards the returned state**
(`{results, _state}`). `:nextrule` (`dispatcher.ex:562`) similarly calls `safe_handle`
and discards `_new_persistent`. Any `set` binding written by a rule reached through
`nextevent` or `nextrule` is silently lost. Triple and data writes survive only because
`TripleStore` and `DataStore` are separate processes.

---

## 4. Frontend Architecture

**There is no user-facing frontend.** No HTML, JS, CSS, template, or asset pipeline
exists in the repository. The only web artefacts are the committed-but-gitignored ExDoc
output in `doc/` (`/doc/` is listed in `.gitignore` and `git ls-files doc` returns zero
tracked files — the directory is a build artefact left in the working tree).

The project's own C4 diagrams use "frontend" in the compiler sense — lexer, parser, AST,
compiler — documented in `arch/diagrams/component-frontend-as-built.c4`. That is covered
in §2.1 and §7 below.

---

## 5. Data Layer

### 5.1 There is no database

No migration directory, no Ecto, no repo, no schema, no SQL. `exqlite` appears in
`mix.lock` only because the `comn` path dependency declares it; nothing in `lib/`
references it. `mix.lock` is itself listed in `.gitignore` yet is tracked in git — the
two are in conflict, and the file currently shows as modified.

**Nothing in Anemos persists across a process restart.** All state is in-memory,
process-resident, and lost on crash.

### 5.2 In-memory stores

| Store | Backing | Keyed by | Lifetime |
|---|---|---|---|
| `ModuleRegistry` | `Agent` holding `%{}` | module name string | Runtime supervisor |
| `ContextStore` | `Agent` holding `%{}` | dotted path string `"a.b.c"` | Runtime supervisor |
| `TripleStore` | `Agent` holding a **list** of `{s,p,o}` | none — linear scan | Dispatcher process |
| `DataStore` | `GenServer` map | `{name, scope_tag}` | Dispatcher process |
| `SubscribableRegistry` | `Agent` holding `%{}` | protocol string | Dispatcher process |
| rule bindings | field in Dispatcher state | rule name string | Dispatcher process |

`TripleStore` stores triples in a plain list and performs a full `Enum.filter` on every
query (`triple_store.ex`, `query/4` and `match/4`). Assertion does an `in` membership
check against the whole list before prepending, making assertion O(n) and n assertions
O(n²). Acceptable at fact counts in the hundreds; not at thousands.

### 5.3 DataStore scoping

`DataStore` keys entries `{name, scope_tag}` where `scope_tag` is `:global` or
`{:local, discriminator}`. Lookup resolves local first, then global (`data_store.ex:219`).

The discriminator is **overloaded**. `maybe_monitor/2` monitors it when it is a pid and
silently skips monitoring otherwise (`data_store.ex:206-215`). The compiler sets it to
the **rule name string** (`compiler.ex:355`), and the dispatcher passes `scope_hint:
rule_name` (`compiler.ex:831-833`). So the automatic cleanup-on-process-death path
described in the `DataStore` moduledoc never fires for the scoping the rest of the system
actually uses. Locally scoped datasets accumulate for the life of the dispatcher.

The moduledoc says scope is `{:local, pid}`; the live callers pass `{:local, String.t()}`.
The documentation and the usage disagree.

### 5.4 Query blocks compile but never run

`Anemos.CompiledQuery` values are produced by `Compiler.compile_query/1` and land in
`%CompilationResult{query_blocks: […]}`. `Dispatcher.handle_call({:load, compiled}, …)`
iterates `compiled.data_blocks` (`dispatcher.ex:218`) but **never touches
`compiled.query_blocks`**. The compiled query's `handler` is a closure that returns
`{:ok, %{engine: …, body: …, bindings: …, context: …}}` — it does not execute anything;
it merely reflects its own inputs back (`compiler.ex:269-271`).

The `query` construct is therefore parse-complete, compile-complete, and
execution-absent. The tests confirm this scope: `test/anemos/query_block_test.exs`
asserts on parse and compile output only.

### 5.5 Data flow between layers

```text
host app ──dispatch(event)──▶ Dispatcher
                                 │
                    context map ─┼─▶ compiled closure ──▶ [operation maps]
                                 │        │
                                 │        ├─ ?var  ──▶ context[:context_data][name]
                                 │        ├─ @var  ──▶ bindings[{:let, name}]   (per-firing)
                                 │        └─ $var  ──▶ bindings[{:set, name}]   (persisted)
                                 │
                                 ├─▶ ModuleRegistry.lookup ──▶ Module.handle_verb/3
                                 ├─▶ TripleStore.assert_triple / match
                                 ├─▶ DataStore.member_any?
                                 ├─▶ Demand.evaluate ──▶ CapabilityServer.execute
                                 └─▶ channel_connector.publish(path, %Envelope{})
```

Only `{:set, _}` keys survive a firing: `build_handler/1` filters the final binding map
to those keys before returning (`compiler.ex:508-512`). `@` bindings are discarded by
construction, which matches the documented sigil semantics.

`ContextStore` — the `Agent` that `Anemos.Runtime.put_context/3` writes to — is
**never read by the dispatch path**. `ContextStore.resolve/3` has no caller in `lib/`
outside its own doctest. `?var` resolution goes to `context[:context_data]`, populated
from the event payload (`runtime.ex:249`), not from the store. A host application that
calls `put_context/3` and then expects `?fqdn` to resolve will get `nil`. The README
documents `put_context/3` as the way to supply `?` values; the code does not implement
that link.

---

## 6. Communication Protocols

Everything is BEAM-local. There is no wire protocol, no serialisation format, no port
binding anywhere in `lib/`.

| Boundary | Mechanism | Shape |
|---|---|---|
| host → runtime | `GenServer.call` via `Anemos.Runtime` API | `dispatch/3`, `load/2`, `register/2,3`, `connect/2`, `condition_state/2` |
| Dispatcher → ConditionServer | `GenServer.cast` then `GenServer.call` barrier | `{:event, name, context}`, `:get_state` |
| ConditionServer → Dispatcher | raw `send/2` from a closure | `{:condition_transition, name}` |
| Dispatcher → CapabilityServer | `GenServer.call` via `Demand.evaluate/3` | `{:execute, context}` |
| Scheduler → Runtime | `Anemos.Runtime.dispatch/2` (a `GenServer.call` into the Dispatcher) | synthetic `AT_*` event names |
| Dispatcher → host modules | direct function call `mod.handle_verb(verb, args, ctx)` | in-process, no isolation |
| Dispatcher → channel | direct call `connector.publish(path, envelope)` | `%Anemos.Envelope{}` |
| `Anemos.Channel.ComnBus` → subscribers | `Comn.EventBus.broadcast/2` → Elixir `Registry` `:duplicate` dispatch | `{:event, topic, %Anemos.Envelope{}}` |

`Anemos.Envelope` (`lib/anemos/envelope.ex`) carries `type` (`:state | :effect | :stream | nil`),
`payload`, `source` (`"rule@context.path"`), `timestamp` (`DateTime.utc_now/0`), `label`,
`channel`, and `signature`. The `signature` field is declared and never populated by any
code path — it is reserved, per the README.

**Verb handlers run in the dispatcher process.** `mod.handle_verb/3` is a direct call, not
a message. A host-supplied module that blocks, sleeps, or performs slow I/O blocks the
entire dispatcher — every rule, every condition, every scheduled event. There is no
timeout, no task supervision, and no pooling on this path. For a system whose stated
purpose is driving infrastructure verbs (`INFRA::get_ip`, `SECRET::unlock`), this is the
single most consequential structural constraint.

---

## 7. External Dependencies

### 7.1 Declared (`mix.exs:38-42`)

| Dependency | Source | Runtime? | What Anemos uses from it |
|---|---|---|---|
| `comn` | **path `../comn`** | yes | `Comn` behaviour, `Comn.Errors.Registry`, `Comn.Discovery`, `Comn.Contexts`, `Comn.EventBus` |
| `nimble_parsec ~> 1.4` | hex | yes | lexer combinators only |
| `ex_doc ~> 0.35` | hex | no (`only: :dev, runtime: false`) | docs generation |

The `comn` path dependency is the material finding here. It resolves to
`/home/imsmith/github/comn` (present, v0.5.0, git-tracked separately). **It is not
published, not pinned, and not vendored.** A clone of the Anemos repository alone will
not compile. `mix.lock` does not and cannot pin a path dependency. This is a hard
build-reproducibility gap.

### 7.2 What Anemos actually calls in Comn

| Call site | Comn API |
|---|---|
| `application.ex:89-90` | `Comn.Errors.Registry.discover/0`, `Comn.Discovery.discover/0` |
| `dispatcher.ex:151` | `Comn.Contexts.with_context/2` |
| `dispatcher.ex:351` | `Comn.Contexts.ContextStruct.new/1` |
| `dispatcher.ex:437`, `:494` | `Comn.Errors.Registry.error!/2` |
| `runtime/errors.ex:403` | `use Comn.Errors.Registry` |
| `channel/comn_bus.ex:476` | `Comn.EventBus.broadcast/2` |
| `module.ex` (macro) | `Comn.Errors.Registry.error!/2` in the generated fallback clause |

Additionally, `Anemos.Runtime`, `Anemos.Runtime.Dispatcher`, `Anemos.Runtime.ModuleRegistry`,
and every module built with `use Anemos.Module` declare `@behaviour Comn` and implement
`look/0`, `recon/0`, `choices/0`, `act/1`. This is an introspection protocol, not a
functional dependency, but it does mean Anemos cannot compile without Comn present.

### 7.3 Transitive dependencies pulled in by Comn

Present in `deps/` and `mix.lock`, **none referenced from Anemos `lib/`**: `gnat` (NATS
client), `exqlite` (SQLite NIF, requires a C toolchain via `elixir_make`/`cc_precompiler`),
`req`/`finch`/`mint`/`hpax` (HTTP), `libgraph`, `jason`, `nkeys`/`kcl`/`ed25519`/
`curve25519`/`salsa20`/`chacha20`/`poly1305` (crypto, via nkeys), `telemetry`,
`db_connection`, `connection`, `cowlib`, `mime`.

The practical consequence: building Anemos requires a working C compiler because
`exqlite` compiles a NIF, even though Anemos never opens a database.

### 7.4 External binaries, APIs, or services

None. No `System.cmd`, no `Port.open`, no HTTP client call, no filesystem write outside
`File.read!` in the Mix task. The `DEVICE` and `FILE` modules that would ordinarily reach
outside the VM are stubs that echo their arguments.

---

## 8. Configuration System

This section is short because the configuration system is, in effect, absent.

### 8.1 Config files

```text
config/config.exs   →  import Config      (1 line, nothing else)
config/dev.exs      →  import Config      (1 line, nothing else)
config/test.exs     →  import Config      (1 line, nothing else)
```

Note also that `config/config.exs` never calls `import_config/1`, so `dev.exs` and
`test.exs` are **not loaded at all**. They are inert files.

`grep` finds no `Application.get_env/2,3`, `Application.fetch_env`, or
`System.get_env` anywhere in `lib/`. There is no environment-variable surface and no
merge or override precedence to document, because there is nothing to merge.

### 8.2 Actual configuration surface

All configuration is passed as function arguments at process start:

| Consumer | Options | Required? |
|---|---|---|
| `Anemos.Runtime.start_link/1` | `:name` | required (`Keyword.fetch!`) |
| `Dispatcher.start_link/1` | `:rules`, `:registry` | required |
| | `:conditions`, `:capabilities` | default `[]` |
| | `:channel_connector` | default `Anemos.Channel.Logger` |
| | `:subscribable_registry` | created if omitted |
| | `:name` | optional |
| `Scheduler.start_link/1` | `:runtime_name` | required |
| | `:dispatch_fn` | test override |
| `ContextStore.start_link/1` | `:data` (list of `{k,v}`) | default `[]` |
| `Anemos.run/2` | `:event` | required |
| | `:context` | default `%{}` |

The runtime derives its child process names by string interpolation on the supervisor
name (`runtime.ex:311-315`): `:"#{name}.supervisor"`, `.registry`, `.context_store`,
`.dispatcher`, `.scheduler`. These are atoms created at runtime from a
caller-supplied term. If a host ever derives runtime names from untrusted input, this
is an unbounded atom-creation path. In practice the name is a compile-time literal in
every observed call site, but nothing in the API enforces that.

### 8.3 CLI

`mix anemos.run <file.rule> --event <EVENT_NAME>`. Argument parsing is hand-rolled
(`Enum.chunk_every(2, 1, :discard)` scanning for the literal `"--event"`), not
`OptionParser`. `--event` is mandatory; anything else is ignored. No other flags exist.

---

## 9. Build System

| Aspect | State |
|---|---|
| Build tool | Mix. `mix compile`, `mix test`, `mix docs`. |
| Protocol consolidation | disabled in `:test`, enabled otherwise (`mix.exs:13`) |
| Extra compile paths | `test/support` added in `:test` (`mix.exs:19`) |
| Formatter | `.formatter.exs` covers `config`, `lib`, `test` |
| Linting | none — no `.credo.exs`, no Dialyzer config, no `dialyxir` dep (the sibling `comn` repo has `.credo.exs`; Anemos does not) |
| CI/CD | **none** — no `.github/`, no `.gitlab-ci.yml`, no pipeline of any kind |
| Docker / containers | none |
| Releases | no `rel/`, no `releases` config in `mix.exs` |
| Packaging | `package/0` declares AGPL-3.0-or-later and files `lib mix.exs LICENSE README* CLAUDE.md`. Publishing to Hex is impossible while `comn` is a path dep. |
| Embedding / asset pipeline | none |

### 9.1 Repository hygiene findings

- `erl_crash.dump` — 5.9 MB, dated 2026-04-16, present in the working tree. Gitignored,
  not tracked. Should be deleted.
- `doc/` — 90+ generated ExDoc files in the working tree. Gitignored, not tracked.
- `mix.lock` — **tracked in git but also listed in `.gitignore`**. Currently shows as
  modified. For a library this is arguably correct-to-track and wrong-to-ignore; the two
  declarations contradict each other and should be reconciled.
- Three `.tcl` design sketches are tracked **twice**: at the repository root and under
  `docs/design-notes/sketches/`. `stop-data-extraction-policy.tcl` at the root is
  currently modified relative to its committed version. These are pre-spec design
  artefacts, not code.
- One untracked file is named `● Here's where we stand against the spec.md` — a leading
  U+25CF and spaces in a filename. It is a stale status note whose content is
  contradicted by both `TODO.md` and the current code (it lists loops, flow control,
  guards, and pipelines as unimplemented; all four are implemented and tested).
- `.legacy/docs/` (where this report lives) was created empty immediately before this
  analysis.

### 9.2 Documentation state

Three documents describe implementation status, and **they disagree with each other**:

| Document | Claim |
|---|---|
| `README.md` "Project Status" | loops, flow control, guards, pipelines, NLD, triples, 14-level precedence all work end-to-end |
| `TODO.md` | loops, flow control, guards, pipelines listed under "Not implemented (15%)"; NLD "token reserved, not implemented"; rule metadata "keywords lexed, not parsed" |
| `● Here's where we stand…md` | same as TODO.md, slightly different ordering |

The **README is the accurate one**. Verified against code and tests: `test/anemos/loop_test.exs`,
`flow_control_test.exs`, `guard_test.exs`, `pipeline_test.exs`, `nld_test.exs`,
`triple_test.exs`, `precedence_test.exs`, `metadata_test.exs` all exist and pass.
`TODO.md` and the `●`-prefixed file are stale and should be deleted or rewritten; leaving
them in place actively misinforms.

`ISSUES.md` (three entries, all dated 2026-08-04) is accurate and current — each of its
three findings was independently confirmed during this analysis.

`arch/diagrams/*.c4` — four LikeC4 files (context, container, two component views) added
in the most recent commit. Spot-checked against the code: accurate, including the
honest annotations that `DataModelRegistry` and `RuleSupervisor` are "present in lib/ but
not started."

---

## 10. Concurrency Model

### 10.1 Process topology

```text
host application supervision tree
└── Anemos.Runtime (Supervisor, :one_for_one)   name: :"<n>.supervisor"
    ├── ModuleRegistry   (Agent)                name: :"<n>.registry"
    ├── ContextStore     (Agent)                name: :"<n>.context_store"
    ├── Dispatcher       (GenServer)            name: :"<n>.dispatcher"
    │   ├── ConditionServer  (GenServer × N)    ── start_link, LINKED not supervised
    │   ├── CapabilityServer (GenServer × M)    ── start_link, LINKED not supervised
    │   ├── TripleStore      (Agent)            ── start_link, LINKED not supervised
    │   ├── DataStore        (GenServer)        ── start_link, LINKED not supervised
    │   └── SubscribableRegistry (Agent)        ── start_link, LINKED not supervised
    └── Scheduler        (GenServer)            name: :"<n>.scheduler"

Anemos.Application → Anemos.Supervisor (:one_for_one, ZERO children)
```

### 10.2 The supervision gap

The five processes the Dispatcher starts are started with `start_link/1` from inside
`Dispatcher.init/1` and `handle_call({:load, …})`. They are **linked to the dispatcher
but not supervised by it** — there is no `Supervisor`, no `child_spec`, no restart
strategy governing them.

`grep` confirms **no `Process.flag(:trap_exit, true)` anywhere in `lib/`**. Consequences:

1. A crash in any `ConditionServer`, `CapabilityServer`, `TripleStore`, `DataStore`, or
   `SubscribableRegistry` propagates an exit signal to the Dispatcher, which is not
   trapping, and the Dispatcher dies.
2. The `Runtime` supervisor restarts the Dispatcher — with the child spec declared in
   `runtime.ex:270-275`, i.e. `rules: [], conditions: [], capabilities: []`.
3. **Every policy loaded via `Anemos.Runtime.load/2` is silently gone.** So are all
   asserted triples, all registered datasets, all condition state, and all `$` bindings.
   The registry survives (separate supervised child), so registered modules persist; the
   policies they implement do not.

There is no reload hook, no policy cache, and no persistence to recover from. The host
application receives no notification that its loaded policies have evaporated — the
supervisor restart is invisible from the outside, and the next `dispatch/3` simply
returns `{:ok, []}`.

This is the most serious architectural defect found. It is not recorded in `ISSUES.md`.

A secondary consequence: `CapabilityServer` rescues four exception types inside
`handle_call` (`capability_server.ex:215-216`) and `Dispatcher.safe_handle/4` rescues
eight. Anything outside those sets — for instance a host module raising a custom
exception struct — takes the same path to dispatcher death.

### 10.3 Serialisation and throughput

Every event dispatch is a single `GenServer.call` into one dispatcher process, and the
entire cycle — condition fan-out, barrier, rule handlers, verb handler invocation,
channel publishing, and any recursive emit re-dispatch — runs inside that one call. The
dispatcher is a global serialisation point per runtime instance. There is no
concurrency within a dispatch and no pipelining across dispatches.

`GenServer.call` uses the default 5,000 ms timeout throughout; no call site overrides it.
A verb handler that takes longer than five seconds will cause the *caller* to exit with a
timeout while the dispatcher continues executing, leaving the two out of sync.

### 10.4 Timers

Two independent timer mechanisms:

**Scheduler timers** (`scheduler.ex:83-120`) — one per `at` block.
`:timer.send_interval/2` for `at interval(…)`; `Process.send_after/3` for one-shot
`{:time, …}`, `{:date, …}`, `{:day, …}`, `{:nld, …}` and for recurring times, which
re-arm themselves in `handle_info({:fire_recurring, …})`. All time arithmetic uses
`NaiveDateTime.local_now/0` — system-local, DST-naive. A recurring `at 09:00 every day`
schedule crossing a DST boundary will fire an hour early or late; there is no handling
for this.

`start_timer/1` for `{:date, …}` returns `nil` if the target is in the past
(`scheduler.ex:106`), and `{:nld, …}` returns `nil` on unresolvable text — in both cases
the returned `nil` is stored in the `timers` map as if it were a timer reference. Nothing
reads it back, so this is currently harmless, but the map's type invariant is violated.

**Dwell timers** (`dispatcher.ex:600-660`) — the `when EVENT for <duration>` state machine.
Per `(rule_name, event_name)`, stored in `rule_bindings` under a `{:dwell, event_name}` key
as `%{state: :listening | :armed, timer_ref:, last_context:}`. Transitions:

```text
:listening + truthy  → :armed      (Process.send_after → {:dwell_fire, rule, event})
:listening + falsy   → :listening
:armed     + truthy  → :armed      (timer NOT restarted; last_context updated)
:armed     + falsy   → :listening  (Process.cancel_timer(info: false))
timer fires          → run body synchronously, → :listening
```

Truthiness is decided by `dwell_signal_truthy?/1`, which looks for a `"state"` or
`:state` key in the event payload and defaults to `true` when neither is present
(`dispatcher.ex:648-656`). This means an event with no payload always arms the timer —
an undocumented and surprising default.

The dwell state lives in the same map as handler-persisted `$` bindings, and
`dispatch_immediate/5` overwrites that map wholesale with the handler's filtered
`{:set, _}`-only output. `handle_info({:dwell_fire, …})` works around this with an
explicit merge of pre-run dwell entries (`dispatcher.ex:307-321`, with a five-line
comment explaining why). The workaround covers the dwell-fire path. It does **not** cover
the case where a non-dwell rule sharing the same `rule.name` fires between arm and expiry
— that path calls `dispatch_immediate/5` directly and will wipe the dwell entry. Multiple
`when` blocks in one `rule` produce multiple `CompiledRule` structs that all share
`rule.name` (`compiler.ex:314-327`), so this collision is reachable from ordinary policy.

### 10.5 Process dictionary usage

Two distinct, deliberate uses:

1. **`Anemos.Compiler`** uses `:anemos_accumulated_ops` to survive the `throw`/`catch`
   used to implement `return`, `done`, `nextevent`, and `nextrule`. When a throw aborts
   an `Enum.reduce`, the in-flight accumulator is lost; the process dictionary carries it
   out. The key is saved and restored around each `eval_body/3`, each `for` iteration, and
   each `while` iteration (`compiler.ex:519-539`, `:644-659`, `:711-723`). The code is
   heavily commented and internally consistent, but it means **the compiler's evaluator is
   not reentrant across processes and not safe to call concurrently on shared state**.
   Since evaluation only ever happens inside the single dispatcher process, this is
   currently sound.
2. **`Comn.Contexts`** stores the request context in the process dictionary, wrapped by
   `with_context/2`. This is a conventional BEAM ambient-context pattern and is documented
   as such in the Comn source.

### 10.6 What is *not* concurrent

- No `Task`, `Task.Supervisor`, `Task.async_stream`, or `Flow` anywhere in `lib/`.
- No pooling of any kind.
- No back-pressure, no queue, no rate limiting.
- `RuleSupervisor` — the `DynamicSupervisor` that would host per-rule processes — exists
  but is never started, so rules do not run as processes. All rules for a runtime share
  the dispatcher's mailbox and scheduler slot.

---

## 11. Summary of Material Findings

Ordered by consequence.

1. **Dispatcher crash destroys all loaded policy.** Five processes are linked to but not
   supervised by the Dispatcher; the Dispatcher does not trap exits; its supervisor child
   spec restarts it with empty rules. Any crash in a condition server, capability server,
   triple store, data store, or subscribable registry silently wipes every loaded policy
   with no notification to the host. (§10.2)
2. **Unbounded emit re-dispatch recursion.** Labelled emits re-enter `dispatch_to_rules/3`
   with no cycle detection or depth limit. Two mutually-emitting rules will exhaust the
   process. (§3.3)
3. **`comn` is an unpublished path dependency.** The repository does not build standalone.
   `mix.lock` cannot pin it. (§7.1)
4. **`put_context/3` does not feed `?` resolution.** `ContextStore` is written by the
   public API and read by nothing. The README documents a link that the code does not
   implement. (§5.5)
5. **Verb handlers execute in the dispatcher process** with no timeout, isolation, or
   supervision. A slow or blocking host module halts the whole runtime. (§6)
6. **`nextrule` / `nextevent` discard state.** Persistent bindings written by rules
   reached through either are silently dropped. (§3.4)
7. **Query blocks and the `DataModel` behaviour are unwired.** They parse, compile, and
   then nothing consumes them. (§2.4, §5.4)
8. **Dwell state and `$` bindings share one map**, with a documented workaround covering
   only one of the two paths that can clobber it. Reachable from a rule with two `when`
   blocks. (§10.4)
9. **Two dead modules** (`RuleSupervisor`, `DataModelRegistry`) ship in the published
   documentation as live API. Already filed in `ISSUES.md`. (§2.3)
10. **`TODO.md` and the `●`-prefixed status file are stale** and contradict both the
    README and the code. (§9.2)
11. **No CI, no linting, no Dialyzer, no reproducible build.** 403 tests pass, but nothing
    enforces that they keep passing. (§9)
12. **`config/dev.exs` and `config/test.exs` are never loaded** — `config.exs` has no
    `import_config/1`. Currently harmless because all three are empty. (§8.1)

### What is in good shape

The test suite is substantial (6,577 lines, 403 tests plus 20 doctests, all passing in
3.4 s) and covers each language feature with a dedicated file. Moduledocs and `@spec`
annotations are present and largely accurate. `ISSUES.md` and the `arch/diagrams/*.c4`
files are honest about the codebase's own gaps, including the dead modules. The process
dictionary usage — normally a red flag — is deliberate, commented with its rationale, and
correct for the single-process execution model it assumes. The dwell-timer state machine
is documented in a design spec (`docs/superpowers/specs/2026-05-18-elseif-and-dwell-timer-design.md`)
that the implementation comment cross-references.

---

## Appendix A — Uncertainties

Points where the code did not settle the question:

- **`safe_handle/4`'s stated exception policy.** The comment says unexpected exception
  types are left to crash; the `catch kind, reason` clause contradicts it for throws and
  exits. Which behaviour is intended is not determinable from the source.
- **`DataStore` scope discriminator type.** Moduledoc says pid; live callers pass a
  string. Whether pid-scoping is a planned future path or abandoned is not stated
  anywhere.
- **`Anemos.AST.Flow`, `.On`, `.It`, `.BlockArgs`** are defined as structs, are documented,
  and are never constructed by the parser. Whether they are placeholders for §4.4–4.6 of
  the language spec or leftovers is unclear; the parser has no `on` / `it` / `flow`
  declaration clause. `BlockArgs` is *read* in `Compiler.eval_statement` for `NextRule`
  args (`compiler.ex:683-687`), but the parser always sets `NextRule.args` to `nil`
  (`parser.ex:1081`), so that branch is unreachable.
- **The language specification itself is not in this repository.** `docs/design-notes/`
  points to an Obsidian vault at `~/Documents/remote.vault.001/src/097 Orders of the System/`.
  Conformance claims in `TODO.md` and the README reference spec section numbers that
  cannot be checked against anything in-tree.

## Appendix B — Method

Every `.ex` file in `lib/` (39 files, 6,455 lines) was read in full. `mix.exs`, all three
`config/*.exs`, `.formatter.exs`, `.gitignore`, `.claude/settings.local.json`, all four
`arch/diagrams/*.c4`, all three `priv/examples/*.rule`, `README.md`, `TODO.md`,
`ISSUES.md`, and `CLAUDE.md` were read in full. The `comn` path dependency was inspected
for the five APIs Anemos consumes. Test files were sampled for scope, not read in full;
the suite was executed (`mix test`, exit 0). Repository hygiene claims were verified with
`git ls-files`. No conclusion in this document rests on inference where the code was
available to read.

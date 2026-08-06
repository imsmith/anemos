# Anemos — Code Quality Forensic Assessment

**Date:** 2026-08-06
**Scope:** `/home/imsmith/github/anemos` @ `80ba1b4`, 39 `.ex` files / 13,083 LOC (lib + test)
**Method:** full read of `lib/`, test suite executed, coverage measured, five architectural
hypotheses tested empirically against a running runtime.

Internal document. Blunt by request.

---

## Summary grades

| # | Area | Grade |
| --- | --- | --- |
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

**Overall:** a well-documented, well-tested *front end* (lexer → parser → compiler) bolted to a
runtime that loses all state on any child crash, spins forever on a two-rule event cycle, and
leaks operations between unrelated rules through the process dictionary. The craftsmanship on
display in the parser and the docs is real. The runtime has not been engineered to the same
standard, and three of its defects are demonstrable in under ten lines of policy.

---

## The four confirmed defects

These were not inferred from reading. Each was reproduced against a live `Anemos.Runtime`.

### D1 — Any child crash destroys every loaded policy (CRITICAL)

`Anemos.Runtime.Dispatcher.init/1` (`lib/anemos/runtime/dispatcher.ex:96-129`) calls `start_link`
on every `ConditionServer`, every `CapabilityServer`, the `TripleStore`, the `DataStore`, and the
`SubscribableRegistry`. These become *linked* processes of the dispatcher, supervised by nobody.
The dispatcher does not trap exits — `Process.flag(:trap_exit, ...)` appears nowhere in `lib/`.

`ConditionServer.handle_cast/2` (`lib/anemos/runtime/condition_server.ex:70`) invokes a
user-supplied evaluator closure with no rescue. Any exception in a policy's condition expression
kills the condition server, which kills the dispatcher.

The dispatcher is then restarted by `Anemos.Runtime`'s supervisor with the child spec at
`lib/anemos/runtime.ex:172-177` — `rules: [], conditions: [], capabilities: []`. Every policy
loaded via `Anemos.Runtime.load/2` is gone. Silently. `dispatch/3` keeps returning `{:ok, []}`
forever.

Reproduced:

```text
H1 {ops_before, same_dispatcher_pid, ops_after_condition_kill}: {1, false, 0}
```

One op before killing the condition server; dispatcher pid changed; zero ops after. No error is
returned to any caller. The system is a silent no-op from that point on.

This is the single worst defect in the tree. It converts every recoverable policy bug into total,
undetectable loss of function.

### D2 — Mutual `nextevent` wedges the dispatcher permanently (CRITICAL)

`execute_op(%{type: :nextevent})` (`lib/anemos/runtime/dispatcher.ex:557`) recurses into
`dispatch_to_rules/3` with no depth counter, no visited-set, and no cycle detection. The same
applies to `emit ... as <label>` re-dispatch (`lib/anemos/runtime/dispatcher.ex:428-432`).

```text
rule a { when A { log "a" nextevent B } }
rule b { when B { log "b" nextevent A } }
```

Reproduced: `H3 mutual nextevent: NO TERMINATION within 4s (infinite loop)`.

The `GenServer.call` caller times out after 5s and crashes; the dispatcher itself keeps recursing
at 100% CPU, growing the stack, until the VM dies. Every subsequent event in the system is blocked
behind it — the dispatcher is the sole serialization point for all dispatch.

Note the contrast: `while` loops *are* bounded (`@while_limit 10_000`,
`lib/anemos/compiler.ex:632`). The author knew to bound unbounded iteration in one place and
missed the other. Per NASA Power of 10 rule 2 (which this project's own doctrine adopts), every
loop needs a fixed upper bound; event recursion is a loop.

### D3 — Process-dictionary flow control leaks ops between unrelated rules (HIGH)

`Anemos.Compiler` implements `return` / `done` / `nextevent` / `nextrule` as `throw`, using
`Process.put(:anemos_accumulated_ops, ...)` to smuggle the in-flight accumulator past the throw
(`lib/anemos/compiler.ex:520-534, 642-690`). The mechanism is deliberate and commented.

It is also unbalanced. `eval_body/3` restores the previous value *only on the normal exit path*
(`lib/anemos/compiler.ex:536-538`). `build_handler/1` catches the throw
(`lib/anemos/compiler.ex:494-502`) and never restores the key. So a handler that hits `return`
leaves its ops in the process dictionary, and the *next* handler in that process to hit `return`
prepends them to its own output.

Reproduced — three rules in one process, `rule a` returns early, then `rule c` returns early:

```text
rule a (return):        {:ok, [%{type: :log, value: "a1"}], %{}}
process dict after throw: [%{type: :log, value: "a1"}]
rule c after leak:      {:ok, [%{type: :log, value: "a1"}, %{type: :log, value: "c1"}], %{}}
```

`rule c` emitted `rule a`'s log operation. In production every rule runs in the one long-lived
dispatcher process, so this leak is permanent and cross-policy: rule A's side effects get executed
again under rule C's name, with rule C's context. For a system whose stated purpose is executing
infrastructure policy, that is a correctness failure with real blast radius.

### D4 — Loading the same policy twice doubles its execution (MEDIUM)

`handle_call({:load, ...})` does `state.rules ++ compiled.rules`
(`lib/anemos/runtime/dispatcher.ex:251`) with no dedup on rule name and no replace semantics.
Reproduced: `H2 ops after loading same policy twice (expect 1): 2`.

`Anemos.Runtime.load/2` is documented as "Can be called multiple times — policies accumulate"
(`lib/anemos/runtime.ex:47-53`), so accumulation is intended — but there is no way to *reload* a
changed policy, and no warning on a duplicate rule name. Any hot-reload story built on this API
will double-fire every rule. The scheduler has the same problem in a worse form (see 11.3).

---

## 1. Code organization — ADEQUATE

The pipeline is legible and the naming is honest: `lexer → parser → ast → compiler → runtime`,
exactly as `CLAUDE.md` advertises. `lib/anemos/runtime/` holds the process layer;
`lib/anemos/channel/` the transport adapters. A newcomer can find things.

Problems:

- **`Compiled*` struct placement is inconsistent.** `CompiledCapability`, `CompiledCondition`, and
  `CompiledSchedule` get their own files. `CompiledRule`, `CompiledData`, `CompiledQuery`, and
  `CompilationResult` are buried at the top of `lib/anemos/compiler.ex:1-74`, ahead of the module
  the file is named for. Four public modules are undiscoverable by filename.
- **`lib/anemos/parser.ex` is 1,946 lines**, one module, ~50 `defp parse_*` clauses. It is
  well-structured recursive descent, but it is the largest single artifact in the tree by 2x and
  has the worst coverage of any core module (66%).
- **Three `.tcl` design sketches sit in the repo root** (`ingress-traffic-policy.tcl`,
  `stop-data-extraction-policy.tcl`, `linkdef virt-9-tuple to mesh.tcl`) *and* are tracked again
  under `docs/design-notes/sketches/`. Two copies, both tracked; the root copy of
  `stop-data-extraction-policy.tcl` is currently modified and diverging.
- **A junk file is tracked in the working tree**: `● Here's where we stand against the spec.md` —
  untracked, leading U+25CF, a stale duplicate of `TODO.md`.
- `Anemos.Runtime.Builtins` declares itself "Not user-facing" (`lib/anemos/runtime/builtins.ex:6`)
  but is fully public with no `@moduledoc false`, no `@doc`, and no `@spec` on any of its four
  functions.

## 2. Error handling — POOR

Three mutually incompatible error representations coexist:

| Style | Example |
| --- | --- |
| Structured `Comn` error | `Comn.Errors.Registry.error!("anemos.runtime/handler_crash", ...)` (`dispatcher.ex:437`) |
| Ad-hoc tuple | `{:error, {:handler_crash, rule.name, reason}}` (`dispatcher.ex:571`) |
| Bare string | `{:error, "Lexer error on line #{line}: #{message}"}` (`parser.ex:62`) |

The same logical failure — a rule handler crashing — produces a structured `Comn` error on the
`dispatch_immediate` path and a raw 3-tuple on the `nextrule` path. Callers cannot pattern-match
uniformly on anything.

Specific failures:

- **`Anemos.Runtime.load/2` discards its own results** (`lib/anemos/runtime.ex:56-65`).
  `Dispatcher.load/2` and `Scheduler.schedule/2` return values are thrown away; the function
  returns a hardcoded `:ok`. Only parse/compile failures ever reach the caller.
- **`Anemos.Runtime.dispatch/3` always returns `{:ok, results}`** (`lib/anemos/runtime.ex:134-144`)
  even when every element of `results` is an `{:error, _}`. The success/failure distinction is
  buried inside the payload. Same in `Anemos.run/2` (`lib/anemos.ex:60-67`).
- **Subscription failures are logged and dropped** (`lib/anemos/runtime/dispatcher.ex:236-245`).
  A data block whose feed fails to subscribe silently becomes an empty `MapSet`, so every
  `memberof()` check against it quietly returns `false`. For an allow/deny-list use case — the
  documented use case — fail-open is the wrong default and the caller is never told.
- **`safe_handle/4`'s catch-all is too wide** (`lib/anemos/runtime/dispatcher.ex:478-480`).
  `catch kind, reason` catches `:exit` as well as `:throw`, so an exit signal from a downstream
  `GenServer.call` timeout inside a module verb is converted into a rule-level error and hidden.
  The `rescue` list above it is explicitly and thoughtfully bounded; the `catch` below undoes that
  discipline.
- **`ConditionServer` and the `Scheduler` have no crash boundary at all** — user closures run bare
  (`condition_server.ex:70`, `scheduler.ex:73`). Compare `CapabilityServer.handle_call/3`
  (`capability_server.ex:52-57`), which does rescue. Inconsistent, and D1 is the consequence.

Where the error handling is good, it is very good: `Anemos.Runtime.Errors` registers three
structured codes, the `safe_handle` rescue list is documented with rationale, and parser errors
carry line numbers on the non-EOF paths.

## 3. Test coverage — ADEQUATE

The suite runs and passes:

```text
20 doctests, 403 tests, 0 failures      (3.1s)
```

29 test files, 821 assertions, 22 of 38 `use ExUnit.Case` declarations `async: true`. Doctests are
used as executable documentation in 12 modules. Error paths are tested, not just happy paths —
`test/anemos/runtime/errors_test.exs`, the `{:error, _}` doctests in `Anemos.run/2`. This is
better than most projects of this age.

But:

```text
Coverage:   73.53%     Threshold:  90.00%     -> mix test --cover FAILS
```

| Module | Coverage |
| --- | --- |
| `Anemos.Runtime.RuleSupervisor` | 0.00% |
| `Mix.Tasks.Anemos.Run` | 0.00% |
| `Anemos.Runtime.Scheduler` | 20.00% |
| `Anemos.Runtime.Modules.File` | 40.00% |
| `Anemos.Parser` | 66.03% |
| `Anemos.Compiler` | 83.27% |
| `Anemos.Runtime.Dispatcher` | 85.65% |

The **Scheduler at 20%** is the alarming number: it is the module with the most branching
(`:weekday`, `:weekend`, seven day atoms, five `time_spec` shapes, DST-naive arithmetic) and the
least verification. The parser at 66% means roughly a third of the grammar's error paths are
unexercised. The CLI task is entirely untested.

Other issues:

- **No CI.** No `.github/`, no `.gitlab-ci.yml`, no Makefile target. Nothing runs this suite except
  a human remembering to.
- **20 `Process.sleep` calls in tests** (`dwell_timer_test.exs`, `runtime_test.exs`,
  `data_store_test.exs`) — wall-clock timing assertions. One commit message in the history
  (`9116ec3 chore: ... widen dwell-test timing window`) is the flake tax already being paid.
- **Test logging is not silenced.** `config/test.exs` contains exactly one line: `import Config`.
  A full run prints hundreds of `[info] [anemos] ...` lines from `execute_op(%{type: :log})`
  (`dispatcher.ex:500`), drowning real failures. `config/config.exs` and `config/dev.exs` are
  likewise empty — three files, zero configuration.
- Two untracked scratch files (`test/scratch_forensics_test.exs`, `test/scratch_recovery_test.exs`)
  are artifacts of concurrent analysis, not codebase content. Delete before committing.

## 4. Type safety — POOR

- **~66 `@spec` across 609 function definitions** (126 `def`, 483 `defp`). Twenty modules have
  zero specs, including `Anemos.AST` (every node struct), `Anemos.Module`, `Anemos.Channel`,
  `Anemos.Runtime.Builtins`, `Anemos.Runtime.Errors`, and both stub verb modules.
- **No Dialyzer.** No `dialyxir` in `deps`, no `:dialyzer` key in `mix.exs`, no PLT, no
  `.dialyzer_ignore`. Nothing has ever checked the specs that do exist for consistency.
- **No Credo** either. There is no static analysis in this project at all.
- The struct `@type t` definitions are genuinely good where present (`CompiledRule`,
  `CompiledData`, `Envelope`), and the behaviours (`Anemos.DataModel`, `Anemos.Subscribable`,
  `Anemos.Runtime.Module`, `Anemos.Event`) are fully typed. The gap is implementations, not
  contracts.
- **The core value in the system is an untyped closure.** `CompiledRule.handler` is
  `(String.t(), map(), map() -> {:ok, [map()], map()})` — every operation is a bare `map()` with a
  `:type` key. `execute_op/3` dispatches on `%{type: :command}`, `%{type: :log}`, … with no struct,
  no `@type operation ::` union, and no compile-time check that the compiler and dispatcher agree
  on the op vocabulary. The two lists are kept in sync by hand and by moduledoc
  (`dispatcher.ex:9-10`). This is the type-safety hole that actually matters here.
- `Map.get(rule, :dwell_duration_ms)` and `Map.get(rule, :meta, %{})`
  (`dispatcher.ex:390, 414`) treat a struct as a bare map, defeating `@enforce_keys` and hiding
  typos behind a `nil` default.

## 5. Code smells — ADEQUATE

Genuinely clean in the ways most codebases are not:

- **Zero `TODO` / `FIXME` / `XXX` / `HACK` comments in `lib/` or `test/`.** Verified by grep. Rare
  and creditable.
- No commented-out code blocks anywhere.
- No compiler warnings, even under `--warnings-as-errors`.
- The comments that exist explain *why*, not *what* — the process-dictionary rationale
  (`compiler.ex:520-524`), the `:activated`-state collapse (`dispatcher.ex:600-618`), the
  rule-name-as-scope-discriminator note (`dispatcher.ex:583-585`). This is above-average commenting.

Against that:

- **The process-dictionary evaluator** (see D3) is the largest smell in the tree — and it is
  load-bearing, not decorative.
- **`mix format --check-formatted` fails** on `lib/anemos/parser.ex` (the hand-aligned
  `@precedence` table, `parser.ex:23-35`). Formatting is otherwise clean, so this one file has
  been edited past the formatter deliberately.
- **`cond` used as a variable name** (`lib/anemos/compiler.ex:130`), shadowing the `cond/1` special
  form.
- **Dead modules**, both already self-reported in `ISSUES.md`: `Anemos.Runtime.RuleSupervisor`
  (0% coverage, referenced only by its own `defmodule`) and `Anemos.Runtime.DataModelRegistry`
  (exercised only by its own tests; superseded by `SubscribableRegistry`). `ISSUES.md` is right
  about both.
- **`handle_call({:load, ...})` is 81 lines** (`dispatcher.ex:183-264`) doing five unrelated jobs:
  starting condition servers, starting capability servers, registering static data, wiring dynamic
  subscriptions, and merging state. Its first 30 lines are near-verbatim duplicates of
  `init/1:96-123` — the condition-server and capability-server construction blocks are copy-pasted,
  including the `on_transition` closure.
- **A 5.9 MB `erl_crash.dump`** sits in the working directory. Correctly gitignored, never cleaned.

## 6. Dependency health — POOR

Three direct dependencies:

```elixir
{:comn, path: "../comn"},          # local path dependency
{:nimble_parsec, "~> 1.4"},        # up to date (1.4.2)
{:ex_doc, "~> 0.35", only: :dev}   # 0.40.1, latest 0.40.3
```

- **`{:comn, path: "../comn"}` makes this repository unbuildable by anyone else, anywhere.** There
  is no git URL, no version, no fallback. Clone Anemos alone and `mix deps.get` fails. Path deps
  do not appear in `mix.lock`, so there is no recorded version of the single dependency that
  matters most — and `comn` is not incidental: it supplies `Comn.Errors.Registry`,
  `Comn.Contexts`, `Comn.Discovery`, `Comn.EventBus`, and the `@behaviour Comn` implemented by
  five modules. Anemos cannot compile without it and cannot tell you which version it needs.
- **The transitive footprint is large and unaudited.** `mix.lock` carries 28 packages — `exqlite`
  (with a C build via `elixir_make`/`cc_precompiler`), `gnat` (NATS), `req`/`finch`/`mint`,
  `libgraph`, and a full crypto stack (`kcl`, `curve25519`, `ed25519`, `salsa20`, `chacha20`,
  `poly1305`). All of it arrives through the unversioned path dep. For a DSL interpreter that is a
  substantial and invisible attack surface.
- **`mix.lock` is listed in `.gitignore` (line 30) but is tracked anyway.** For an application this
  should be committed — as it in fact is — so the `.gitignore` entry is simply wrong and will
  confuse the next person who touches it. It is currently showing as modified.
- Nothing is abandoned; `ex_doc` is two patches behind. That part is fine.

## 7. Naming — ADEQUATE

No misspellings found in public API names — a clean sweep, which is unusual. Conventions are
consistent: `snake_case` functions, `?`-suffixed predicates (`member?`, `periodic?`, `truthy?`),
`CamelCase` modules matching file paths.

Issues:

- **`transclude` vs `transduce`.** `Anemos.DataModel` declares a `transduce/3` callback
  (`data_model.ex:20`) while the same module's moduledoc says the runtime "delegates parsing,
  evaluation, and **transclude**" (`data_model.ex:7`). Meanwhile `CompiledData` has a `:transclude`
  field, `AST.DataDecl` has `:transclude`, `DataStore` has `:transcluded`, and the lexer reserves
  `transclude` as a keyword. Two different words, one of them appearing in a doc where the other
  belongs. A reader cannot tell whether these are the same concept.
- **`TripleStore`'s moduledoc documents a function that does not exist**:
  `TripleStore.assert(store, "p001", "knows", "p002")` (`triple_store.ex:10`). The function is
  `assert_triple/4`. Copy the example, get an `UndefinedFunctionError`.
- **`Dispatcher.condition_state/2` vs `DataStore.member?/4`** — the same "query current state"
  operation, named without a `?` in one place and with one in the other.
- **`{:set_connector, connector}` has no client function.** `Anemos.Runtime.connect/2` reaches into
  the dispatcher with a raw `GenServer.call` (`runtime.ex:109`) for a message the dispatcher
  handles (`dispatcher.ex:281`) but does not expose or document. Every other dispatcher message has
  a documented wrapper.
- `name` vs `name_str` in `ConditionServer`/`CapabilityServer` opts — `:name` is the *process*
  registration and `:name_str` is the *condition's* name. Workable, but it is a trap and it is
  documented only in the opts list.

## 8. Architectural debt — CRITICAL

Beyond D1–D4:

- **One process is the entire runtime.** Every event, every rule body, every module verb call, and
  every nested `emit`/`nextevent` executes inside a single `Dispatcher` `handle_call`. There is no
  concurrency, no backpressure, and no isolation between policies. A module verb that does network
  I/O blocks *all* dispatch, and the default 5 s `GenServer.call` timeout applies to the whole
  cascade — a rule fanning out to twenty verbs will time out its caller while continuing to run.
  The BEAM's central advantage is not being used. `RuleSupervisor` exists precisely to fix this and
  has never been wired in.
- **Mailbox draining as a synchronization primitive.** `handle_call({:dispatch, ...})` casts to
  every condition server, then calls `get_state` on every one purely as a memory barrier, then
  selectively `receive`s `{:condition_transition, _}` out of its own mailbox
  (`dispatcher.ex:153-164`, `452-462`). This is an ad-hoc rendezvous built from three primitives
  where one `GenServer.call` per condition would do. It is O(conditions) round-trips per event and
  it breaks the moment a condition transition is produced by anything other than the current
  dispatch — as the code itself admits at `dispatcher.ex:335-338`, where out-of-cycle transitions
  are *silently discarded*. Level-triggered conditions therefore lose edges.
- **Nested dispatch discards state.** `execute_op(%{type: :nextevent})` binds
  `{results, _state} = dispatch_to_rules(...)` (`dispatcher.ex:558`) and throws the state away;
  `:nextrule` discards `_new_persistent` (`dispatcher.ex:568`). Confirmed: after
  `rule outer → nextevent B → rule inner { set c = 5 }`, `rule_bindings` contains only
  `%{"outer" => %{{:set, "n"} => 1}}`. Every `set` in a rule reached via flow control is lost.
- **`TripleStore` is an unbounded list with linear dedup.** `assert_triple/4` does
  `if triple in triples` (`triple_store.ex:41-46`) — O(n) per assert, O(n²) to build, and the list
  is never pruned or persisted. A long-running policy that asserts facts degrades continuously and
  then exhausts memory. A `MapSet` (used elsewhere in this codebase) would fix the constant factor;
  the unboundedness needs a real answer.
- **The dwell-timer state machine is fighting the binding store.** `handle_info({:dwell_fire, ...})`
  needs 20 lines of comment and a three-way merge (`dispatcher.ex:307-321`) to stop rule-body
  execution from wiping dwell entries, because timer state and user `set` bindings share one map
  keyed by rule name. Two different lifetimes in one namespace, reconciled by hand on every fire.
- **Context matching is naive prefix matching.** `context_matches?/2` does
  `String.starts_with?(event_context, rule_context)` (`dispatcher.ex:448`) with no segment
  boundary. Confirmed: a rule scoped to `"garage"` fires on an event from `"garageband.studio"`.
  Given that context is documented as an *exclusionary* boundary, this is a policy-scoping
  correctness bug — the exact class of bug that matters in an authorization-adjacent DSL.
- **`Anemos.Application` starts an empty supervisor** (`application.ex:15`) whose only effect is two
  `discover/0` calls. Already filed in `ISSUES.md`; still true.

## 9. Build and CI — POOR

- **No CI whatsoever.** No `.github/workflows`, no pipeline config of any kind. 128 commits, zero
  automated verification.
- **No linting or static analysis.** No Credo, no Dialyzer, no Sobelow.
- **`mix format --check-formatted` currently fails.** `.formatter.exs` is correct and minimal; one
  file has drifted.
- **`mix test --cover` currently fails** the default 90% threshold at 73.53%. No `test_coverage`
  config in `mix.exs` to either enforce a chosen number or document the exemption.
- `mix.exs` itself is clean and correct: `elixirc_paths` split for test support,
  `consolidate_protocols: false` in test (needed — `Anemos.Event` is a protocol),
  `start_permanent` in prod, proper `package` block with `licenses: ["AGPL-3.0-or-later"]`.
  Nothing wrong here.
- **`.gitignore` is mostly right** (`_build`, `deps`, `doc`, `cover`, `erl_crash.dump`,
  `.worktrees`) with one error: it ignores `mix.lock`, which is nonetheless tracked. It does not
  ignore `.elixir_ls/` or `.codegraph/` artifacts.
- **Generated `doc/` output exists on disk** (~100 HTML + Markdown files) and is correctly
  gitignored — but `ISSUES.md` treats the published docs as a deliverable, so there is an
  unautomated publish step somewhere outside the repo.

## 10. Documentation — GOOD

The strongest area by a wide margin.

- **`README.md`, 514 lines**, 30 sections: quick example, a genuinely illustrative richer example,
  integration instructions with supervision-tree code, then a construct-by-construct language tour
  (rules, conditions, capabilities, context, guards, variables, loops, flow control, scheduling,
  modules, emit, triples, expressions, the event protocol, channel connectors), architecture,
  status, and license. It is accurate against the code as far as I checked it.
- **`@moduledoc` on every public module**, most with usage examples. 20 doctests execute as part of
  the suite, so the examples cannot silently rot.
- **`ISSUES.md` is exemplary.** Three issues, each with symptom, verbatim grep evidence, file/line
  citations, a "why it happens" section, and a concrete "what should change." I independently
  confirmed all three. Whoever wrote this was doing the job properly.
- **`docs/superpowers/specs/` and `docs/plans/`** carry dated design specs and implementation plans
  per feature, and the git history shows the discipline being followed (`docs: design spec` →
  `docs: implementation plan` → `feat:` → `test:`). The commit history is the best-organized part
  of this project.

Against that:

- **`TODO.md` is stale to the point of being misleading.** It lists "Not implemented (15%): Loops,
  Flow control, Guards, Pipelines" — all four of which are implemented, tested, and marked done in
  the same repository's git history and `README.md`. It also mixes three checkbox conventions
  (`- ✅`, `-[x] ⚠️`, `- ❌`) and carries heavy trailing whitespace.
- **`● Here's where we stand against the spec.md`** is a third, untracked, differently-stale copy of
  the same status information, with a U+25CF in the filename.
- `arch/diagrams/component-frontend-as-built.c4` documents a "frontend" component that has no
  corresponding code.
- The moduledoc/code mismatches noted in §7 (`TripleStore.assert`, `transclude`/`transduce`).

## 11. Elixir/OTP-specific — CRITICAL

Consolidating, since these are the findings that decide the overall grade.

1. **Supervision tree is wrong** (D1). Children started with `start_link` from inside a GenServer
   `init`, no supervisor, no `trap_exit`, no restart of state. `RuleSupervisor` — the
   `DynamicSupervisor` that would fix it — is dead code.
2. **Unbounded recursion inside a GenServer callback** (D2). No depth limit on `nextevent` or
   `emit` re-dispatch.
3. **Timer leaks in the Scheduler.** `state.timers` is keyed by `event_name`
   (`scheduler.ex:50-53`); scheduling a second `at` block with the same event name overwrites the
   entry and *never cancels the old timer*, which keeps firing forever. There is no unschedule API
   at all, so a reloaded policy accumulates duplicate live timers indefinitely. Worse: on a
   Scheduler crash the supervisor restarts it with `timers: %{}, schedules: []` — every schedule is
   silently lost, exactly as in D1.
4. **Scheduler can deadlock-by-timeout against the Dispatcher.** `do_dispatch/2`
   (`scheduler.ex:73-79`) makes a `GenServer.call` into the dispatcher with the default 5 s
   timeout, from inside `handle_info`. Any slow rule body kills the scheduler and drops its timers.
5. **Process dictionary used for cross-call state** (D3) — the canonical BEAM anti-pattern, and
   here it is provably leaking.
6. **No `Registry` usage.** Process addressing is done with dynamically-constructed atoms —
   `:"#{name}.dispatcher"` (`runtime.ex:213-217`). If runtime names ever come from user input or
   policy files, this is an atom-table exhaustion vector; even with trusted names it forgoes
   `Registry`'s process lifecycle integration for no benefit.
7. **No timeouts specified anywhere.** Every `GenServer.call` in `lib/` uses the 5 s default, on
   paths that explicitly invoke user-supplied module verbs that may do arbitrary I/O.
8. **Unbounded GenServer state.** `TripleStore` list (above), `Dispatcher.rules` (append-only, no
   dedup), `Scheduler.schedules` (append-only, never pruned), `rule_bindings` holding full context
   maps in `last_context` for every armed dwell timer.
9. `handle_info({:condition_transition, _name})` silently drops messages by design
   (`dispatcher.ex:335-338`) — the only "unexpected message" handler in the tree, and it discards
   real signals rather than unexpected ones.

What is done *right*: `use GenServer`/`use Agent` with `@impl true` throughout; `MapSet` for
subscription membership; `Process.monitor` with proper `:DOWN` cleanup in `DataStore`
(`data_store.ex:187-198`) — the one place lifecycle is handled correctly, and it is handled well;
`Process.cancel_timer(ref, info: false)` used correctly; behaviours (`Anemos.Channel`,
`Anemos.Runtime.Module`, `Anemos.DataModel`, `Anemos.Subscribable`) with `@impl` on implementations;
a protocol (`Anemos.Event`) for the extension point that genuinely needs one. The author knows OTP.
The runtime process layer just did not get the same attention as the compiler.

## 12. Frontend — N/A

No frontend exists. `notebooks/playground.livemd` is a Livebook scratchpad and
`arch/diagrams/component-frontend-as-built.c4` documents a component with no code behind it —
either the diagram is aspirational or it is stale. The only user-facing surface is
`mix anemos.run` (`lib/mix/tasks/anemos.run.ex`), which is untested (0% coverage) and whose
argument parsing hand-rolls `--event` extraction with `Enum.chunk_every/4` instead of
`OptionParser`.

---

## Prioritized fixes

**P0 — correctness and availability. Nothing else matters until these are done.**

1. **Fix the supervision tree (D1).** Move `ConditionServer`, `CapabilityServer`, `TripleStore`,
   `DataStore`, and `SubscribableRegistry` under a real supervisor — `RuleSupervisor` is already
   written for this. Make the dispatcher trap exits, or better, stop it from owning process
   lifecycles at all. Persist loaded policies outside the dispatcher's state so a restart does not
   silently zero the system. Add `rescue` around the `ConditionServer` evaluator.
   *Regression test: kill each child, assert policies still fire.*
2. **Bound event recursion (D2).** Add a depth counter (or a visited-event set) threaded through
   `dispatch_to_rules/3`, with a configurable ceiling and a structured error on breach. Apply to
   `nextevent`, `nextrule`, and `emit`-label re-dispatch alike.
   *Regression test: the two-rule cycle above must terminate with an error.*
3. **Kill the process-dictionary evaluator (D3).** Thread the accumulator through the throw payload
   itself — `throw({:anemos_return, ops_so_far, bindings})` already carries ops, so the dictionary
   is redundant on the throw path; the `Enum.reduce` accumulator just needs to be reachable, which a
   `reduce_while` or an explicit fold with an `{:halt, _}` shape gives you without global state.
   Minimum viable fix if the rewrite is deferred: wrap `build_handler`'s body in `try/after` that
   restores the key. *Regression test: the three-rule leak above.*
4. **Fix context boundary matching.** `String.starts_with?` must become segment-aware —
   `event_context == rule_context or String.starts_with?(event_context, rule_context <> ".")`.
   *Regression test: `"garage"` must not match `"garageband.studio"`.*

**P1 — state integrity.**

5. Propagate state out of nested dispatch: stop discarding `_state` in `:nextevent` and
   `_new_persistent` in `:nextrule` (`dispatcher.ex:558, 568`).
6. Give `Dispatcher.load/2` replace-or-reject semantics on duplicate rule names, and add an
   unload/reload path. Same for `Scheduler.schedule/2`, plus timer cancellation — currently the
   only way to stop a schedule is to kill the VM.
7. Make `Anemos.Runtime.load/2` return the results it currently swallows, and make `dispatch/3`
   return `{:error, _}` when the operation list contains errors.
8. Replace `TripleStore`'s list with a `MapSet` and decide a retention policy.

**P2 — engineering hygiene.**

9. Add CI: `mix format --check-formatted`, `mix test`, `mix test --cover` with an explicit
   threshold. This is a half-hour of work that would have caught two of the items already in this
   report.
10. Add `dialyxir` and `credo`; bring spec coverage up on the runtime modules first. Define an
    `@type operation ::` union so the compiler and dispatcher agree on the op vocabulary by
    contract rather than by moduledoc.
11. Silence Logger in `config/test.exs`; the three config files are currently empty.
12. Raise Scheduler coverage from 20% — it has the most branches and the least verification, and
    its time arithmetic is `NaiveDateTime.local_now/0` throughout, i.e. DST-unsafe by construction.
13. Replace `Process.sleep` timing assertions with message-based synchronization.

**P3 — cleanup.**

14. Resolve the `{:comn, path: "../comn"}` dependency into something other machines can resolve —
    a git ref at minimum, a published package ideally. Until then this repo is unbuildable by
    anyone but its author.
15. Act on the three issues in `ISSUES.md` (they are correct); delete or wire in `RuleSupervisor`
    and `DataModelRegistry`.
16. Delete `TODO.md` or rewrite it — it currently contradicts the README, the git history, and the
    code. Delete `● Here's where we stand against the spec.md`. De-duplicate the three root-level
    `.tcl` sketches against `docs/design-notes/sketches/`. Remove `mix.lock` from `.gitignore`.
    Delete `erl_crash.dump` and the untracked `test/scratch_*.exs` files.
17. Move `CompiledRule`/`CompiledData`/`CompiledQuery`/`CompilationResult` out of `compiler.ex`
    into their own files, matching the three that already are. Extract the duplicated
    condition/capability server construction shared by `Dispatcher.init/1` and
    `handle_call({:load, ...})`. Run the formatter on `parser.ex`.
18. Fix `TripleStore`'s moduledoc example, settle `transclude` vs `transduce`, give
    `{:set_connector, _}` a documented client function, and mark `Runtime.Builtins`
    `@moduledoc false`.

---

## Closing assessment

This is not a low-quality codebase. The lexer, parser, and compiler are careful work: 403 passing
tests, doctests as living documentation, zero `TODO`s, zero warnings, a README that could ship, and
an `ISSUES.md` that self-reports its own dead code with grep evidence and line numbers. The commit
history shows spec → plan → implement → test, executed consistently across 128 commits.

The runtime did not get that treatment. Four defects are reproducible in minutes, three of them
cause silent, total, unrecoverable loss of function, and all four are in the layer that would run
unattended in production. The pattern is consistent: the compiler was engineered, the process layer
was assembled. `RuleSupervisor` sitting unwired since v0.1.0 is the tell — the right design was
identified and never built.

Fix P0 before this runs anything that matters. The rest is ordinary debt.

# Anemos — Data Flow, Process Lifecycle, and State Transitions

Forensic analysis of `/home/imsmith/github/anemos` at commit `80ba1b4` (branch `main`).
Method: full read of `lib/` (~3,300 LOC across 39 files), plus executable probes run
against the live system to confirm or refute each suspected defect. Findings marked
**[CONFIRMED]** were reproduced by running code, not inferred from reading. Probe
sources are preserved in the session scratchpad
(`scratch_forensics_test.exs`, `scratch_recovery_test.exs`) and were removed from
`test/` so they do not join the project suite.

Baseline: `mix test` → 20 doctests, 403 tests, 0 failures.

---

## §0 — What this system actually is

The brief asked about queues, batch jobs, subprocesses, HTTP integrations, databases,
and file serving. **None of these exist.** Anemos is a single-node, in-memory
interpreter for an event-driven policy DSL. There is no HTTP client or server, no
`:ets`/`:dets`/SQLite/Ecto, no `Port`/`System.cmd`/`Task`, no filesystem writes
anywhere in `lib/` outside a `File.read!` in the Mix task, and no authentication of
any kind. Verified by exhaustive grep.

The sections below map the brief's questions onto the constructs that do exist. Where
a category is genuinely empty, that is stated rather than padded.

The whole system is **one GenServer doing everything**: `Anemos.Runtime.Dispatcher`
(`lib/anemos/runtime/dispatcher.ex`, 664 lines) holds the rule index, executes rule
bodies, calls out to modules, publishes to channels, runs the dwell state machine,
and owns the triple store and data store. Every finding below flows from that shape.

---

## §1 — Primary workflow lifecycle

There are two entry paths.

### One-shot: `Anemos.run/2` (`lib/anemos.ex:37-74`)

`source string → Parser.parse → Compiler.compile → ModuleRegistry.start_link →
Dispatcher.start_link → Dispatcher.dispatch → GenServer.stop`.

Used by `mix anemos.run` (`lib/mix/tasks/anemos.run.ex:19`). Stateless, single event,
tears itself down.

### Long-lived: `Anemos.Runtime` (`lib/anemos/runtime.ex`)

A `Supervisor` (`:one_for_one`) started by the host application with a `:name`. Four
children (`lib/anemos/runtime.ex:169-181`), all registered under derived atom names:

| Child | Type | Name |
| --- | --- | --- |
| `ModuleRegistry` | Agent | `:"<name>.registry"` |
| `ContextStore` | Agent | `:"<name>.context_store"` |
| `Dispatcher` | GenServer | `:"<name>.dispatcher"` |
| `Scheduler` | GenServer | `:"<name>.scheduler"` |

The dispatcher starts **blank** (`rules: []`). Policies arrive later via
`Anemos.Runtime.load/2`, which parses, compiles, pushes rules/conditions/capabilities
into the dispatcher and schedules into the scheduler (`lib/anemos/runtime.ex:56-65`).

### The dispatch cycle — `handle_call({:dispatch, ...})` (`dispatcher.ex:147-180`)

Every step runs synchronously inside the dispatcher process, wrapped in a
`Comn.Contexts.with_context/2` carrying a generated `request_id`, the event name as
`parent_event_id`, and any caller-supplied `correlation_id`/`trace_id`/`actor`
(`dispatcher.ex:341-356`).

1. **Fan out to conditions.** `ConditionServer.handle_event/3` is an async `cast` to
   every condition server — *all* of them, unfiltered; each server does its own
   subscription check (`condition_server.ex:71`).
2. **Barrier.** A `get_state` **call** to every condition server. This is a deliberate
   synchronization trick: because a `call` to a process cannot be answered before that
   process finishes the earlier `cast`, returning from the call proves every condition
   has been evaluated and any `on_transition` message is already in the dispatcher's
   mailbox. Correct, but O(2N) messages per event with N conditions, every event.
3. **Drain transitions.** `collect_transitions/1` (`dispatcher.ex:456-462`) does a
   selective `receive` with `after 0` to pull `{:condition_transition, name}` messages.
4. **Dispatch to rules** for the real event, then again for each synthetic
   `CONDITION_<name>` event.
5. Return the accumulated result list.

### Per-rule execution — `dispatch_immediate/5` (`dispatcher.ex:401-441`)

1. Load the rule's persistent bindings from `state.rule_bindings[rule.name]`.
2. Enrich context with `:data_store` pid and `:_rule_name`.
3. Call the compiled handler closure inside `safe_handle/4` — a `rescue` list of eight
   exception types plus a bare `catch kind, reason` (`dispatcher.ex:467-480`). Anything
   not in that list is deliberately left to crash the dispatcher.
4. Write back the returned persistent bindings.
5. `execute_op/3` each operation in order.
6. Split out `{:emit_event, label, op}` results and recursively re-dispatch each label
   as a new event.

### Progress reporting and completion

There is none. `dispatch/3` blocks until the entire cascade finishes and returns a flat
list of `{:ok, op}` / `{:error, err}` tuples. `Anemos.Runtime.dispatch/3`
(`runtime.ex:134-144`) **always returns `{:ok, results}`** with errors embedded in the
list — the caller cannot distinguish total success from total failure without scanning
every element. There is no aggregate status, no partial-progress signal, and no way to
observe an in-flight dispatch.

---

## §2 — Process/task management

### What spawns processes

No OS subprocesses. No `Task`, no `Port`, no `System.cmd`. Nothing parses subprocess
output because nothing produces any.

BEAM processes are spawned in exactly three places:

- `Dispatcher.init/1` (`dispatcher.ex:92-144`) — one `ConditionServer` per condition,
  one `CapabilityServer` per capability, plus a `TripleStore`, a `DataStore`, and
  (optionally) a `SubscribableRegistry`.
- `Dispatcher.handle_call({:load, ...})` (`dispatcher.ex:183-264`) — more condition and
  capability servers, merged into the existing maps.
- `Anemos.Runtime.init/1` — the four supervised children.

### How they are monitored and killed

**They aren't.** Every one of those processes is created with `start_link` *from inside
the dispatcher*, which means they are linked to the dispatcher but supervised by
nobody. There is no `DynamicSupervisor` in the path. `Anemos.Runtime.RuleSupervisor`
exists (`runtime/rule_supervisor.ex`) but is referenced by zero call sites — already
filed in `ISSUES.md`.

There is no kill path, no shutdown path, and no replacement path. `Dispatcher.load/2`
does `Map.merge(state.condition_servers, new_condition_servers)`
(`dispatcher.ex:252`), so re-loading a policy that redefines condition `"c"` silently
**orphans** the previous `ConditionServer` — it stays alive, stays linked, and is
unreachable.

### [CONFIRMED] `Anemos.run/2` leaks four processes per call

`Anemos.run/2` stops the dispatcher with `GenServer.stop/1`, which exits with reason
`:normal`. A `:normal` exit signal is ignored by non-trapping linked processes, so the
`TripleStore`, `DataStore`, `SubscribableRegistry`, and every `ConditionServer` /
`CapabilityServer` survive the dispatcher's death permanently.

Probe: 20 calls to `Anemos.run/2` with one condition and one rule.

```text
B process count before/after 20 runs: {156, 236}
```

80 processes leaked across 20 calls — exactly 4 per call, never reclaimed. For the
`mix anemos.run` CLI this is harmless (the VM exits). For any host that calls
`Anemos.run/2` in a loop it is an unbounded leak.

---

## §3 — Queue / job system

There is no queue. There is no job system. There is no concurrency to bound.

The concurrency model is: **one process, one message queue, strictly serial**. The
dispatcher's mailbox *is* the queue, and it is unbounded and unprioritized. Rule bodies,
module verbs, capability handlers, and channel publishes all execute inside the
dispatcher's `handle_call`.

### [CONFIRMED] Any slow module verb wedges the entire runtime

`Dispatcher.dispatch/3` is a bare `GenServer.call/2` (`dispatcher.ex:52`) with the
**default 5,000 ms timeout** and no override option. `execute_op` for `:command` calls
`mod.handle_verb/3` synchronously (`dispatcher.ex:492`) — arbitrary host code with no
timeout, no supervision, and no isolation.

Probe: a module verb that sleeps 6 seconds.

```text
I dispatch with 6s verb: {:exited, :timeout}
```

The caller is killed by the timeout while the dispatcher continues running the verb.
For the remaining second every other event — including scheduler-fired ones — queues
behind it. Since `Scheduler.do_dispatch/2` (`scheduler.ex:75-81`) calls
`Anemos.Runtime.dispatch/2` from inside its own `handle_info`, a slow verb blocks the
scheduler too, delaying every unrelated timer.

**A module verb that calls back into the dispatcher deadlocks permanently.** Nothing
prevents this and nothing detects it.

### Unbounded recursion inside the call

Three op types recurse into `dispatch_to_rules/3` with no depth limit and no cycle
detection:

- `:emit` with a `label` (`dispatcher.ex:527-532` → `401-441`)
- `:nextevent` (`dispatcher.ex:557-560`)
- `:nextrule` (`dispatcher.ex:562-574`)

A rule that emits a label matching its own subscription recurses until the stack blows.
The `@while_limit 10_000` guard in the compiler (`compiler.ex:636`) does not cover any
of these paths.

---

## §4 — Batch / collection processing

Collections are handled entirely at compile-evaluation time by pipeline builtins
(`runtime/builtins.ex`, 56 lines) driven from `eval_pipe/4` (`compiler.ex:869-910`).

| Builtin | Implementation | Semantics |
| --- | --- | --- |
| `filter` | `Enum.filter` | binds each element into `context[:context_data][var]` |
| `map` | `Enum.map` | same binding mechanism |
| `reduce` | `Enum.reduce` | accumulator injected as `bindings[{:set, acc_name}]` |
| `emit` | `Enum.each` | side-effecting; returns the input collection unchanged |

No splitting, no chunking, no parallelism, no backpressure. `Builtins.emit/4`
(`builtins.ex:44-52`) discards each `command_fn` result via `Enum.each` and returns
the original collection — commands built inside a piped `emit` are **constructed and
thrown away**, never reaching `execute_op`.

### Loop bounds

- `while` is bounded at 10,000 iterations (`compiler.ex:636, 704-707`) and **silently
  truncates** — no error, no log, no marker in the result. A policy whose loop runs
  long is indistinguishable from one that completed.
- `for` (`compiler.ex:644-659`) has **no bound at all**. `resolve_iterable/3`
  `List.wrap`s whatever the expression produced and iterates it inside the dispatcher's
  `handle_call`.

Both violate the "bounded loops" principle the project's own doctrine calls for, in
opposite directions: one bounds silently, the other not at all.

---

## §5 — Monitoring / polling systems

### Dwell timers (level-triggered event watching)

`when <EVENT> for <duration>` compiles to a `dwell_duration_ms` on the rule
(`compiler.ex:318, 446-454`; zero durations are a compile error). The state machine
lives in the dispatcher (`dispatcher.ex:600-660`), keyed
`rule_bindings[rule_name][{:dwell, event_name}]`:

```text
:listening + truthy -> :armed     (Process.send_after)
:listening + falsy  -> :listening
:armed     + truthy -> :armed     (timer NOT restarted; last_context updated)
:armed     + falsy  -> :listening (Process.cancel_timer)
timer fires         -> run body synchronously, return to :listening
```

Truthiness comes from `context[:context_data]["state"]` (or the atom key), and
**defaults to `true` when neither key is present** (`dispatcher.ex:648-656`). Any event
without a `state` field therefore always arms and can never be cancelled — the dwell
degrades into an unconditional delayed fire.

#### [CONFIRMED] A sibling `when` block destroys armed dwell state

`rule_bindings` is keyed by **rule name only**, but a rule with multiple `when` blocks
compiles to multiple `CompiledRule` structs that all share that name
(`compiler.ex:314-327`). `dispatch_immediate` overwrites
`rule_bindings[rule.name]` with `new_persistent`, which `build_handler` has filtered
down to `{:set, _}` keys only (`compiler.ex:508-513`) — wiping any `{:dwell, _}` entry.

The `handle_info({:dwell_fire, ...})` clause carries a long comment
(`dispatcher.ex:305-321`) patching this for the case where the dwell body itself fires.
It does not cover the case where a *different* `when` block of the same rule fires while
a dwell is armed.

Probe: `rule r { when OTHER {...} when SIGNAL for 200ms {...} }` — arm the dwell, then
fire `OTHER`.

```text
D rule_bindings after sibling fire: %{"r" => %{}}
```

The armed entry is gone. The pending `Process.send_after` still fires 200 ms later,
finds no entry, matches the `_ ->` clause and is **dropped silently as "stale"**
(`dispatcher.ex:328-331`). The dwell body never runs, and nothing anywhere reports it.

Same root cause: `handle_info({:dwell_fire, ...})` locates the rule with
`Enum.find(state.rules, fn r -> r.name == rule_name and event_name in r.subscriptions end)`
(`dispatcher.ex:298`) — first match wins, so two `when` blocks in one rule watching the
same event are silently collapsed to one.

### Condition servers (state watching)

One GenServer per condition (`runtime/condition_server.ex`, 85 lines), holding a single
boolean, transitioning on `false → true` only. The compiler currently emits
`evaluator = fn _event_name, _context -> true end` (`compiler.ex:204`) — **every
condition fires on the first subscribed event it sees, unconditionally**. The trigger
expression is parsed but never compiled into the evaluator. Condition bodies become a
`side_effect_handler` closure whose returned ops are **discarded** by the server
(`condition_server.ex:75`): `if state.side_effect_handler, do: state.side_effect_handler.()`.
The ops go nowhere. Only the `CONDITION_<name>` synthetic event escapes.

### Data-block subscriptions

`data … dynamic { subscribe <protocol> <uri> }` resolves a handler through
`SubscribableRegistry` and calls `handler.subscribe(protocol, uri, callback)`
(`dispatcher.ex:224-247`). The callback closes over the `DataStore` pid and calls
`DataStore.update/4` when new data arrives.

The returned `{:ok, ref}` is **matched and thrown away** (`dispatcher.ex:237`). Nothing
stores it. `Anemos.Subscribable.unsubscribe/1` and `periodic?/0` are declared
(`subscribable.ex:13-19`) and called from nowhere in `lib/`. Subscriptions are
create-only: they cannot be cancelled, listed, or restarted, and they outlive the data
block they feed. The `periodic` half of the parsed `{{:subscribe, ...}, periodic}`
tuple is destructured and discarded — **polling is parsed but not implemented**.

Failures are `Logger.warning` only (`dispatcher.ex:240, 244`) — `load/2` still returns
`:ok`, so a policy whose entire data source failed to connect reports success.

---

## §6 — Data parsing

### Source text → AST

`Anemos.Lexer` (NimbleParsec, 554 lines) → `Anemos.Parser` (recursive descent, 1,946
lines) → `Anemos.AST` structs (258 lines). Parse errors carry line/col. This is the
one genuinely complete subsystem.

### AST → closures

`Anemos.Compiler` (911 lines) walks the AST and builds Elixir closures directly — no
`Module.create`, no code generation. `%CompiledRule{handler: fn event, ctx, bindings ->
{:ok, ops, new_bindings} end}`. Rule bodies are therefore *interpreted at dispatch
time*, not compiled.

#### [CONFIRMED] Process-dictionary contamination across rules — silent duplicate execution

The compiler uses a single process-dictionary key, `:anemos_accumulated_ops`, to let
`return`/`done`/`nextevent`/`nextrule` throws capture the ops built so far
(`compiler.ex:519-539, 664-691`). `eval_body/3` saves the previous value and restores it
**on the normal path only** (`compiler.ex:537`). When a `throw` unwinds, the restore is
skipped, and `build_handler`'s `catch` (`compiler.ex:498-505`) does not clean up either.

The stale value survives into the next rule handled by the same process — which, since
all rules run in the dispatcher, is every subsequent rule.

Probe: two independent rules on the same event, each `log … return log …`:

```text
A logs (expect [a1, b1]): ["b1", "b1", "a1"]
```

Rule `b` runs first (the index prepends, so subscription order is reversed —
`dispatcher.ex:482-488`), logs `b1`, and leaves `[b1]` in the dictionary. Rule `a` then
reads `[b1]` as its baseline and returns `[b1, a1]`, so **`b1` is executed a second
time**.

Here the leaked op was a `log`. The same path carries `:command` ops, so **a device or
file command from one rule can be re-executed by an unrelated rule** that happens to use
`return`. This is the most serious defect found: silent, non-deterministic (it depends
on rule ordering within the index), and invisible in the result list, which simply shows
one extra op.

### Runtime value parsing

Everything else is direct Elixir term manipulation in `eval_condition/3`
(`compiler.ex:798-865`). Two notes:

- `:matches_regex` calls `Regex.compile!(to_string(r))` **on every evaluation**
  (`compiler.ex:826`) — no caching, and a policy-supplied pattern against
  policy-supplied data runs inside the single dispatcher process. Catastrophic
  backtracking stalls the whole runtime.
- The fallthrough clause is `_ -> false` (`compiler.ex:849`). An unrecognized operator
  evaluates to false rather than erroring.

### Pluggable format handlers — declared, never invoked

`Anemos.DataModel` (`data_model.ex`) declares `keyword/0`, `parse/1`, `eval/2`,
`transduce/3`. `compile_data/1` stores `format` and `raw` for `{:format_block, kw, raw}`
content (`compiler.ex:245-253`), and then **nothing ever reads them**. Grep for
`DataModel.` in `lib/` returns nothing outside the behaviour definition itself.
`data … { edn { … } }` parses and compiles cleanly and produces an entry with
`dataset: nil`, which `Dispatcher.load` skips at `if data.dataset do`
(`dispatcher.ex:219`). The block is accepted and silently ignored.

Query blocks are the same story: `compile_query/1` builds a handler that just echoes
its inputs (`compiler.ex:269-271`), `query_blocks` is carried through
`CompilationResult`, and no runtime code path reads that field.

---

## §7 — Storage systems

There is no database, no schema, no archive, and no history. Four in-memory stores, all
lost on restart:

| Store | Impl | Owner | Contents |
| --- | --- | --- | --- |
| `TripleStore` | Agent, plain **list** | Dispatcher (unsupervised) | `{s, p, o}` facts |
| `DataStore` | GenServer, map | Dispatcher (unsupervised) | named datasets |
| `ContextStore` | Agent, map | Runtime supervisor | dotted-path key/value |
| `rule_bindings` | Dispatcher state map | Dispatcher | `set` vars + dwell state |

### TripleStore (`runtime/triple_store.ex`)

A list with linear scan on every query and an `if triple in triples` dedup check on every
assert (`triple_store.ex:44`) — **O(n) insert, O(n) query, unbounded growth**. Facts are
append-only; there is no retract operation and no size limit. A rule asserting a triple
per event grows this list forever, and each assert gets slower.

### DataStore (`runtime/data_store.ex`)

Keyed `{name, scope_tag}` where scope is `:global` or `{:local, discriminator}`. Local
shadows global (`data_store.ex:219-228`).

Two problems:

- **Scope discriminators are inconsistent.** `member?/4` accepts a `:scope_hint`, and the
  dispatcher passes the *rule name string* (`dispatcher.ex:409` → `compiler.ex:832`).
  But `get/2` hardcodes `self()` (`data_store.ex:104`) — so `get` can **never** reach a
  rule-scoped entry. Two lookup functions, two different scope models.
- **Rule-scoped entries are never garbage collected.** `maybe_monitor/2` only monitors
  when the discriminator is a pid (`data_store.ex:206-215`); the `{:local, name}` clause
  is an explicit no-op. Since the dispatcher always passes rule-name strings, the
  `:DOWN` cleanup handler (`data_store.ex:187-198`) is **unreachable in practice**.
  Every policy reload adds entries that are never removed.

### rule_bindings

Plain map in dispatcher state, keyed by rule name. Holds `{:set, name}` persistent
variables, `{:until_tripped}` guard flags, and `{:dwell, event}` timer state — three
different lifetimes in one namespace, with the collision consequences documented in §5.

---

## §8 — Scheduled tasks

`Anemos.Runtime.Scheduler` (`runtime/scheduler.ex`, 222 lines). No cron. Timers are
`Process.send_after/3` for one-shots and `:timer.send_interval/2` for intervals, both
tracked in `state.timers` **keyed by event name** (`scheduler.ex:52`).

`at` blocks compile to a synthetic event name derived from the time spec
(`compiler.ex:416-442`): `AT_08_00`, `AT_INTERVAL_5min`, `AT_DATE_2026_01_01`,
`AT_DAY_monday`, `AT_NLD_next_week`. Each produces both a `CompiledSchedule` and a
`CompiledRule` named `at_<event_name>` subscribing to it.

### [CONFIRMED] Same-time schedules collide and leak timers

The event name is a pure function of the time — it carries no rule identity. Two rules
with `at 08:00`:

```text
F schedule event names: ["AT_08_00", "AT_08_00"]
F rules: [{"at_AT_08_00", ["AT_08_00"]}, {"at_AT_08_00", ["AT_08_00"]}]
```

Three consequences:

1. `Map.put(timers, sched.event_name, {timer_ref, sched})` overwrites the first entry.
   The first timer is **never cancelled** and still fires — a leaked timer producing a
   spurious dispatch.
2. Both compiled rules subscribe to `AT_08_00`, so a single fire runs both bodies. That
   happens to be the desired outcome, but by accident, not design.
3. Both rules are named `at_AT_08_00`, so they **share one `rule_bindings` entry** — the
   §5 dwell/binding collision, now across unrelated rules in unrelated files.

### Other scheduler gaps

- **Silent no-scheduling.** `start_timer` for `{:date, ...}` returns `nil` when the date
  is past (`scheduler.ex:104-107`), and for `{:nld, text}` returns `nil` on a zero or
  unresolvable expression (`scheduler.ex:114-120`). Either way `{nil, sched}` is stored
  and `schedule/2` returns `:ok`. A schedule that will never fire is indistinguishable
  from one that will.
- **No removal API.** `handle_call({:schedule, ...})` is the only mutation. Timers cannot
  be cancelled and `state.schedules` grows on every `load/2` — repeated reloads
  accumulate duplicate timers for the same events.
- **Interval timers are permanent.** `:timer.send_interval` is never cancelled, and its
  ref shares the same map slot as one-shot refs with no type tag.
- **No drift correction, no missed-fire detection, no catch-up.** All times use
  `NaiveDateTime.local_now()` — **DST transitions and clock changes are unhandled**, and
  a recurring 02:30 job silently double-fires or skips on transition days.
- **Recurrence only exists for `{:time, {h, m}}`.** `schedule_next_occurrence/1`
  (`scheduler.ex:122-125`) has exactly one clause. A recurring day-of-week or date spec
  fires once and stops.

---

## §9 — Persistence and recovery

**Everything is in memory. Nothing is durable. There is no persist/restore cycle.**

Lost on any dispatcher restart: all loaded rules, conditions, capabilities, all triples,
all datasets, all `set` variables, all armed dwell timers.

### [CONFIRMED] A crash in any unsupervised store silently discards every loaded policy

`TripleStore` and `DataStore` are `start_link`ed from inside `Dispatcher.init/1`
(`dispatcher.ex:125-126`) — linked to the dispatcher, supervised by nothing. The
dispatcher does not trap exits. Its supervisor child spec pins `rules: []`
(`runtime.ex:172-177`), so the restart brings back an **empty interpreter**.

Probe: load a rule, confirm it fires, `Process.exit(triple_store, :kill)`, re-dispatch.

```text
H ops before crash (expect 1): 1
H same dispatcher pid? / restarted?: {false, true}
H ops after crash (expect 1 if recovered): 0
```

The dispatcher restarted cleanly and the policy is gone. `dispatch/3` returns
`{:ok, []}` — **byte-identical to "no rule matched"**. There is no error, no log, no
supervisor message the host can observe. A production system would silently stop
enforcing every policy it had loaded and continue reporting success on every event.

The same applies to any `ConditionServer` or `CapabilityServer` crash: all are linked to
the dispatcher, none are supervised, and any of them dying takes the whole interpreter's
state with it.

Because `Anemos.Runtime` uses `:one_for_one`, the `Scheduler` survives the dispatcher's
restart with its timers intact — and then fires `AT_*` events into an empty dispatcher
forever.

### [CONFIRMED] Reload is additive with no deduplication

`Dispatcher.load/2` does `state.rules ++ compiled.rules` (`dispatcher.ex:251`) with no
identity check.

```text
C log ops after loading same rule twice (expect 1): 2
```

Loading the same policy file twice makes every rule in it fire twice. There is no
`unload`, no `replace`, and no way to inspect what is loaded. Combined with the
no-durable-state finding, the only recovery procedure available to a host is "restart
and reload everything" — which is also the only way to *break* the system by doing it
twice.

---

## §10 — Third-party integrations

Two outbound seams, no inbound ones, and **no authentication anywhere in the codebase**
— no credentials, tokens, headers, TLS config, or auth lifecycle of any kind.

### Channels (outbound)

`Anemos.Channel` behaviour: one callback, `publish(channel, envelope)`.

- `Anemos.Channel.Logger` (default) — `Logger.info`.
- `Anemos.Channel.ComnBus` — `Comn.EventBus.broadcast/2`.

`emit … to channel(path)` builds an `%Anemos.Envelope{}` (`dispatcher.ex:516-524`) with
type, payload, source (`"<rule>@<context>"`), label, channel, and `DateTime.utc_now()`.
The struct declares a `:signature` field (`envelope.ex:18`) that **nothing ever
populates** — signing is designed and unimplemented.

The publish result is **discarded** (`dispatcher.ex:524` — the value of the `if` is
dropped). A channel connector returning `{:error, reason}` is indistinguishable from
success, and the emit still reports `{:ok, op}`.

`Anemos.Runtime.connect/2` swaps connectors via a `GenServer.call` to
`{:set_connector, connector}` — note this handler exists in the dispatcher
(`dispatcher.ex:281-283`) but is **undocumented in the module's client API section**,
reachable only through `Runtime.connect/2`.

### Subscribables (inbound)

Covered in §5. Create-only, no unsubscribe, no polling, failures downgraded to warnings.

### Verb modules (bidirectional)

`Anemos.Runtime.Module` behaviour, one callback: `handle_verb(verb, args, context)`.
`use Anemos.Module, name: "X"` generates the dispatch clauses plus a catch-all returning
`anemos.runtime/unknown_verb` (`module.ex:86-90`).

**Both shipped modules are stubs.** `Modules.Device` and `Modules.File`
(`runtime/modules/device.ex`, `runtime/modules/file.ex`) echo their arguments back as
maps and touch nothing. `Anemos.run/2` registers them as `@default_modules`
(`anemos.ex:14-17`), so the one-shot path and `mix anemos.run` exercise a system where
no verb has any effect. Every example in `priv/examples/` runs against these stubs.

---

## §11 — File management

`Anemos.Runtime.Modules.File` handles `read`, `write`, `rename`, `extension` — all four
return `%{module: "FILE", verb: …, args: args}` and perform **no filesystem operation
whatsoever**. There is no listing, no serving, no deletion, no path validation, and no
access control, because there is no file access.

The only real filesystem read in `lib/` is `File.read!(file)` in the Mix task
(`mix/tasks/anemos.run.ex:21`), unvalidated — appropriate for a developer CLI.

Note for whoever implements the real FILE module: verb args arrive as fully-resolved
values from policy text, and `execute_op` passes them straight through
(`dispatcher.ex:492`) with no sanitization layer between the DSL and the handler. The
`context` map handed to every verb also carries the `:data_store` pid
(`dispatcher.ex:408`) — a live process handle exposed to every third-party verb
implementation.

---

## §12 — Observability

Minimal, and structurally incapable of reporting the failures documented above.

### What exists

- `Logger.info("[anemos] …")` for `:log` ops (`dispatcher.ex:500`) and channel emits
  (`channel/logger.ex:18`).
- `Logger.warning` for subscription failures (`dispatcher.ex:240, 244`) and inline
  dynamic data blocks (`compiler.ex:292-296`).
- `Comn.Contexts` enrichment per dispatch: `request_id` (8 random bytes, base32),
  `parent_event_id`, and pass-through `correlation_id` / `trace_id` / `actor`
  (`dispatcher.ex:341-356`).
- Three structured error codes in `Anemos.Runtime.Errors`: `handler_crash`,
  `unknown_module`, `unknown_verb`.
- `Comn` behaviour implementations (`look/0`, `recon/0`, `choices/0`, `act/1`) on
  `Runtime`, `Dispatcher`, `ModuleRegistry`, and every generated verb module — static
  self-description, not live state.

### What is missing

There is **no status API**. No metrics, no counters, no health check, no way to ask a
running interpreter what rules it has loaded, which conditions are true (except one at a
time by name via `condition_state/2`), which dwell timers are armed, what is in the
triple store, or what schedules are pending. Every probe in this analysis had to reach
into `:sys.get_state/1` to see anything.

There is no frontend and no real-time data path to one.

### Two observability holes with direct operational consequence

1. **The dwell-cancel path is silent by design.** `handle_info({:dwell_fire, ...})`
   comments its `_ ->` clause as "Stale fire — rule was cancelled or already fired. Drop
   silently" (`dispatcher.ex:328-330`). As shown in §5, that clause also swallows the
   binding-collision bug. A dwell that never fires produces no output at any log level.
2. **The `Comn` trace context does not cover timer-driven execution.**
   `build_comn_context/2` is only called from `handle_call({:dispatch, ...})`. Rule
   bodies fired by `handle_info({:dwell_fire, ...})` (`dispatcher.ex:302`) run
   **outside** `Comn.Contexts.with_context/2`, so every error raised by a dwell-fired
   rule loses its `request_id` and `trace_id`. Scheduler-fired events re-enter through
   `dispatch/3` and do get a context, but a freshly generated one with no link to
   whatever caused the schedule to be loaded.

---

## §13 — Context matching

`context_matches?/2` (`dispatcher.ex:443-450`) filters rules by context path.

### [CONFIRMED] Prefix matching without a separator boundary

```elixir
rule_context -> String.starts_with?(event_context, rule_context)
```

Probe: rule scoped to `garage`, event with context path `garageband.amp`:

```text
E dispatch with context garageband.amp: [ok: %{type: :log, value: "matched"}]
```

The rule fired. Context boundaries are meant to be exclusionary; a rule scoped to
`garage` should not see `garageband` traffic. The fix is a separator check
(`event_context == rule_context or String.starts_with?(event_context, rule_context <> ".")`).

### Unscoped events bypass all context scoping

`context_matches?(_rule, nil), do: true` (`dispatcher.ex:443`). An event dispatched with
no `:context_path` matches **every** rule, including context-scoped ones. Whether this is
intended is unclear from the code — but combined with `Anemos.Runtime.dispatch/3`'s
string form, which defaults `context` to `%{}` (`runtime.ex:132`), it means the simplest
and most likely call in any host application silently disables context isolation
entirely.

---

## §14 — `nextrule` / `nextevent` state loss

### [CONFIRMED] `nextrule` discards the target rule's persistent bindings

`execute_op(%{type: :nextrule, ...})` (`dispatcher.ex:562-574`) calls the target
handler and destructures `{:ok, ops, _new_persistent}` — **the updated bindings are
discarded**. It also reads `state` rather than any threaded state, so nothing it does
is visible to the rest of the dispatch.

Probe: `rule counter { when TICK { set n = 1 log $n } }` invoked via `nextrule`:

```text
G nextrule results: [ok: %{type: :log, value: 1}]
G rule_bindings after nextrule: %{"caller" => %{}}
```

The body ran, but there is no `"counter"` key at all — `set n = 1` evaporated. A rule
that maintains a counter across invocations produces correct output when called
directly and silently resets every time it is reached via `nextrule`.

`nextrule` also passes a synthetic event name `"nextrule:#{target}"` (`dispatcher.ex:567`)
which no subscription can match, and drops the `args` resolved by the compiler
(`compiler.ex:682-691`) — `nextrule foo { a: 1 }` parses, compiles, and the arguments
go nowhere.

`execute_op(%{type: :nextevent, ...})` (`dispatcher.ex:557-560`) has the mirror problem:
`{results, _state} = dispatch_to_rules(...)` — the state is explicitly discarded, so any
`set` binding, data registration, or dwell arming performed by the chained rules is lost.

---

## §15 — Summary of defects, by severity

### Critical — silent incorrect execution

| # | Defect | Evidence |
| --- | --- | --- |
| 1 | Process-dictionary leak re-executes a prior rule's operations | §6, probe A |
| 2 | Store crash silently discards all loaded policies; dispatch still returns `{:ok, []}` | §9, probe H |
| 3 | Sibling `when` block destroys armed dwell state; timer dropped silently | §5, probe D |
| 4 | Condition evaluators are hardcoded `true` — every condition fires unconditionally | §5, `compiler.ex:204` |

### High — data loss and resource exhaustion

| # | Defect | Evidence |
| --- | --- | --- |
| 5 | Any slow module verb wedges the entire runtime (5s default call timeout, no isolation) | §3, probe I |
| 6 | Duplicate `load/2` duplicates every rule; no unload, no dedup | §9, probe C |
| 7 | `nextrule` / `nextevent` discard all state produced by the chained rule | §14, probe G |
| 8 | `Anemos.run/2` leaks 4 processes per call | §2, probe B |
| 9 | Same-time `at` blocks collide: leaked timer, shared bindings, shared rule name | §8, probe F |
| 10 | Unbounded recursion via `emit`-label / `nextevent` / `nextrule` cycles | §3 |
| 11 | Rule-scoped DataStore entries are never garbage collected | §7 |
| 12 | TripleStore is an unbounded list with O(n) insert and no retract | §7 |

### Medium — silent no-ops and boundary errors

| # | Defect | Evidence |
| --- | --- | --- |
| 13 | Context prefix matching lacks a separator boundary (`garage` matches `garageband`) | §13, probe E |
| 14 | Events with no context path match every context-scoped rule | §13 |
| 15 | Condition body operations are computed and discarded | §5 |
| 16 | Piped `emit` builds command ops and discards them | §4 |
| 17 | `data { <format> { … } }` blocks parse, compile, and are ignored — `DataModel` never invoked | §6 |
| 18 | Query blocks are compiled into `CompilationResult` and never read | §6 |
| 19 | Channel publish errors are discarded; emit reports success regardless | §10 |
| 20 | Subscription refs discarded — no unsubscribe path; `periodic` parsed but unimplemented | §5 |
| 21 | Past-dated and unresolvable-NLD schedules store a `nil` timer and report `:ok` | §8 |
| 22 | Recurrence implemented only for `{:time, {h,m}}`; other recurring specs fire once | §8 |
| 23 | `while` truncates at 10,000 iterations silently; `for` has no bound at all | §4 |
| 24 | `NaiveDateTime.local_now()` throughout — DST and clock changes unhandled | §8 |
| 25 | Dwell defaults to truthy when no `state` key — cannot be cancelled | §5 |
| 26 | Dwell-fired rule bodies run outside the `Comn` trace context | §12 |
| 27 | `Regex.compile!` per evaluation; policy-supplied patterns run in the shared process | §6 |
| 28 | `dispatch` always returns `{:ok, …}`; errors are embedded, no aggregate status | §1 |
| 29 | `Envelope.signature` declared, never populated | §10 |

### Dead code

`RuleSupervisor`, `DataModelRegistry`, and the empty `Anemos.Application` child list are
already documented in `ISSUES.md`. Additionally dead: `execute_op` clauses for
`:register_data` and `:register_query` (`dispatcher.ex:576-598`) — the compiler moved
inline data registration to load time (`compiler.ex:693-696` explicitly skips them at
runtime), so no code path can emit those op types. `DataStore.deregister/3` and
`SubscribableRegistry.list/1` have no `lib/` callers.

---

## §16 — The one structural recommendation

Every critical finding traces to the same decision: **the dispatcher is simultaneously
the router, the interpreter, the effect executor, and the owner of all mutable state, in
one unsupervised process.**

That single choice produces the process-dictionary contamination (one dictionary shared by
all rules), the wedging (host code runs in the router's `handle_call`), the total policy
loss on crash (state lives in the process that runs untrusted closures), the binding
collisions (one flat map keyed by rule name), and the recursion hazards (re-entrant calls
into `dispatch_to_rules` from within a dispatch).

Splitting effect execution out of the dispatcher — even just running `execute_op` in a
supervised `Task` with a timeout, and moving `rule_bindings` / `TripleStore` / `DataStore`
under the `Runtime` supervisor rather than under the dispatcher — would close findings
1, 2, 5, 10, and most of 3 at once. Nothing else in the codebase needs to change first.

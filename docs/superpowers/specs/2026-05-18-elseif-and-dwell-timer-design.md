# `elseif` and `for <duration>` — Design Spec

## Overview

Two adjacent fixes to existing-but-incomplete language features:

1. **`elseif`** — parser has clauses for it (`parser.ex:925`) but zero tests exercise the path; verify behaviour end-to-end, fix anything broken, add coverage.
2. **`for <duration>`** — captured into `AST.When.duration` by the parser, then dropped on the floor by the compiler. Define runtime semantics (dwell-timer state machine) and wire it through compiler + dispatcher.

Both land in the same spec because they're small adjacent gaps in already-shipped features, and bundling avoids two design-doc roundtrips.

## Part 1: `elseif`

### Current state

- Lexer: `elseif` is in `@keywords` (`lexer.ex:12`).
- Parser: `parse_optional_else` has two clauses — one for `:else` (handling both `else { ... }` and `else if { ... }`), one for `:elseif` (`parser.ex:925`) that recursively calls `parse_if`. The `:elseif` clause produces an `If` node and wraps it as the parent's `else_body`.
- Compiler: nothing special — recursive `If` nodes in `else_body` already evaluate correctly via the existing `If` handling at `compiler.ex:566`.
- Tests: **zero** tests exercise `elseif` (verified by `grep -rn elseif test/`).

### Work

1. Write end-to-end tests for chained `if/elseif/else`:
   - Two-arm chain: `if A { } elseif B { }`
   - Three-arm chain: `if A { } elseif B { } else { }`
   - Long chain: `if A { } elseif B { } elseif C { } elseif D { } else { }`
   - Mid-chain match (verify earlier branches don't fire)
   - All-false-no-else (no body fires)
2. If tests pass, ship as-is. If they fail, fix.
3. Verify parser also accepts `else if X { }` (two-token form) since the `:else` clause already handles it — add a test alongside.

### Out of scope

- Any change to `if` semantics. Just confirming `elseif` reaches the right `If` AST shape and the compiler walks it correctly.

## Part 2: `for <duration>` — dwell timer

### Semantic model

`when EVENT for <duration> { body }` arms a dwell timer keyed on the signal carried by EVENT. The body fires when EVENT's signal stays `true` for the full duration.

**Signal model** (new, applies only to dwell-timer paths — no impact on existing `when` semantics without `for`):

- Each `(rule_name, event_name)` pair has a signal state: `true | false`. Default is `false`.
- Event arrival with a truthy payload (or no payload field) → signal goes `true`.
- Event arrival with a falsy payload → signal goes `false`.
- Truthiness of an event payload is determined by looking at a reserved `:state` key (or `"state"` string key) in the payload map (via `context[:context_data]["state"]` / `:state`):
  - Key missing, or no payload map at all → treated as `true` (the event "happened")
  - Key present with value `false` or `nil` → `false`
  - Key present with any other value → `true`

Standard Elixir truthiness — only `false` and `nil` are falsy. No special-case for `0` / `""`. Callers who want those treated as falsy should pass `false` explicitly.

### State machine

```
                  signal goes true (false→true)
   listening ───────────────────────────────────► armed
       ▲                                            │
       │                                            │
       │ signal goes false (true→false)             │ timer expires
       │ (cancel timer)                             │ while signal true
       │                                            ▼
       └─────────────────── listening ◄────── activated
                              ▲                  │
                              │ body completes   │ run body
                              └──────────────────┘
```

States per `(rule_name, event_name)`:

- **listening**: idle. No timer. Signal is false (or initial).
- **armed**: timer running. Signal is true.
- **activated**: body is executing. Transient — returns to listening when body completes.

Transitions:

| From | Trigger | To | Side effect |
|---|---|---|---|
| listening | event arrives, payload truthy | armed | start `Process.send_after` timer for duration |
| listening | event arrives, payload falsy | listening | none |
| armed | event arrives, payload truthy | armed | none — **timer does NOT restart** |
| armed | event arrives, payload falsy | listening | cancel timer |
| armed | timer expires | activated → listening | run rule handler with last-known context; return to listening when body completes |

### AST and compiler

- `AST.When.duration` already exists as `{integer, atom}` (e.g., `{10, :min}`); no AST change needed.
- `CompiledRule` gains a `dwell_duration_ms` field (or stores `nil`/`ms-integer` in `meta`). Computed from `When.duration` via the existing `duration_to_ms/1` helper in `scheduler.ex` — extract that to a shared helper (e.g., `Anemos.Runtime.Duration.to_ms/1`) so dispatcher and scheduler share it.
- `compile_rule/1` reads `When.duration`, converts to ms, attaches to the compiled rule.
- `for 0min` / `for 0s` → compile-time `{:error, ...}`. Zero-duration is meaningless.

### Dispatcher integration

The dwell-timer path lives in `Dispatcher` because it already owns per-rule persistent state via `rule_bindings` and already handles event routing.

- New per-rule state under `rule_bindings[rule_name]` at key `{:dwell, event_name}`:
  ```elixir
  %{state: :listening | :armed, timer_ref: reference() | nil, last_context: map() | nil}
  ```
- `dispatch_to_rules/3` checks each matching rule for `dwell_duration_ms`:
  - If `nil` (no `for`) → existing immediate-fire path (unchanged).
  - If set → route to a new `handle_dwell/4` that runs the state machine.
- `handle_dwell/4`:
  - Resolve signal truthiness from `context[:context_data]["state"]` or `context[:context_data][:state]` (consistent with how Anemos.Event.payload/1 populates `context_data`).
  - Look up current `{:dwell, event_name}` state in `rule_bindings`.
  - Apply the transition table above. On `listening → armed`, call `Process.send_after(self(), {:dwell_fire, rule_name, event_name}, ms)` and stash the context. On `armed → listening`, call `Process.cancel_timer(ref)`.
- New `handle_info({:dwell_fire, rule_name, event_name}, state)` clause on the Dispatcher:
  - Pull the stashed `last_context` from `rule_bindings[rule_name][{:dwell, event_name}]`.
  - Mark state `:activated`, invoke the compiled rule's handler (synchronously, in the dispatcher process — same as existing dispatch).
  - Apply the resulting ops (commands/log/emit/etc.) via existing `execute_op/3`.
  - On completion, reset `{:dwell, event_name}` to `%{state: :listening, timer_ref: nil, last_context: nil}`.

### Multiple `when ... for` blocks per rule

Each `(rule_name, event_name)` pair is independently keyed in `rule_bindings`, so a rule with two `for`-bearing `when` blocks (different events, different durations) gets two independent dwell timers. No cross-talk.

### Restart semantics

Dispatcher restart (supervisor restart) wipes `rule_bindings`. All in-flight dwell timers die with the process. Documented limitation — same caveat already applies to `set` bindings, listed in `project_status.md`.

### Testing

- **Unit (dispatcher-level, using short durations like 50ms):**
  - listening → armed on truthy-payload event
  - listening stays put on falsy-payload event
  - armed stays armed on second truthy-payload event (verify timer NOT restarted: measure firing time from FIRST arrival, not second)
  - armed → listening on falsy-payload event (verify timer cancelled — no fire after duration)
  - armed → activated → listening on timer expiry (verify body ops in results)
  - Two `(rule, event)` pairs with different durations run independently
- **Integration (full Runtime):**
  - garage-lights-off scenario with a 50ms dwell — verify body fires after one SENSOR_NO_MOTION + 50ms wait
  - cancellation: fire SENSOR_NO_MOTION (truthy), then SENSOR_NO_MOTION with `%{state: false}` 25ms in → verify body never fires
- **Compile-time:**
  - `for 0min` → compile error
  - `for 5min` reaches `CompiledRule.dwell_duration_ms` as `300_000`

### Out of scope

- **Paired/inverse event syntax** (e.g., `when X for 10min cancel Y`). Future feature — wait for an event-state model design pass.
- **Edge vs level event distinction** at the language level. The signal model above is internal to the dwell-timer path; events without `for` retain today's pure-arrival semantics.
- **Persistence across dispatcher restart.** Same limitation as `set` bindings.
- **`for <duration>` on `if` or `at` blocks.** Parser only accepts `for` after `when` today; this spec doesn't change that.

## File-level changes summary

| File | Change |
|---|---|
| `lib/anemos/runtime/duration.ex` | New — extracted `to_ms/1` from `scheduler.ex` |
| `lib/anemos/runtime/scheduler.ex` | Delegate to `Anemos.Runtime.Duration.to_ms/1` |
| `lib/anemos/compiled_rule.ex` (in `compiler.ex`) | Add `:dwell_duration_ms` field (or use `meta`) |
| `lib/anemos/compiler.ex` | Read `When.duration`, attach to `CompiledRule`; reject zero-duration |
| `lib/anemos/runtime/dispatcher.ex` | Dwell-timer state machine, new `handle_info({:dwell_fire, ...})` clause |
| `test/anemos/elseif_test.exs` | New — `if/elseif/else` end-to-end coverage |
| `test/anemos/dwell_timer_test.exs` | New — state machine + integration |

## Exit criteria

```
mix compile --warnings-as-errors  → 0 errors
mix test                          → green (existing + new)
elseif chains                     → work in parser + compiler + dispatcher
when X for 10min { ... }          → body fires after sustained 10min, not on each arrival
when X for 10min { ... } + falsy  → timer cancels, body never fires
project_status.md                 → both items moved out of "not yet implemented"
```

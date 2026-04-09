# `at` Temporal Triggers — Design Spec

## Goal

Implement the `at` trigger block from the language specification (section 4.2), enabling clock-driven event sources in conditions and rules. Scope: numerical time forms and intervals. `NLD_` (natural language dates) is a recognized but unimplemented token type for now.

## Grammar (from spec)

```ebnf
<at-block>      ::= "at" <time-spec> [ <guard> ] "{" <statement-list> "}"

<time-spec>     ::= <time-literal>
                  | "interval" "(" <duration> ")"
                  | <time-literal> "every" <recurrence>

<time-literal>  ::= "TIME_" <HHMM>
                  | "DATE_" <YYYY.MM.DD>
                  | "DAY_" <weekday>
                  | "NLD_" <natural-language-date>
                  | <HH> ":" <MM> [ "AM" | "PM" ]

<recurrence>    ::= <duration>
                  | "day" | "weekday" | "weekend"
                  | <weekday>
```

## Scope

### In scope (this build)

- `at 13:00 { ... }` — fire at next occurrence of 13:00:00, one-shot
- `at TIME_1300 { ... }` — equivalent prefixed form
- `at DATE_2026.04.15 { ... }` — fire at 00:00:01 on that date, one-shot
- `at DAY_monday { ... }` — fire at 00:00:01 on next monday, one-shot
- `at interval(5min) { ... }` — fire every 5 minutes, repeating
- `at 13:00 every day { ... }` — fire at 13:00 every day, repeating
- `at 09:00 every monday { ... }` — fire at 09:00 every monday, repeating
- `at 13:00 every weekday { ... }` — fire at 13:00 monday through friday
- `at` inside conditions — condition becomes true at the scheduled time
- `at` inside rules — rule body executes at the scheduled time
- Guards: deferred. The `guard` field on the AST node is populated but not evaluated.

### Out of scope

- `NLD_` natural language dates — token type reserved, parser returns error
- `AM`/`PM` suffix on time literals — parse but normalize to 24h internally
- Timezone handling — all times are system-local for now
- `unless`/`until` guard evaluation

## Architecture

### New process: `Anemos.Runtime.Scheduler`

A GenServer under the Runtime supervisor. It holds compiled `at` specs, manages timers, and dispatches into the runtime when they fire.

```
Anemos.Runtime (Supervisor)
├── ModuleRegistry (Agent)
├── ContextStore (Agent)
├── Dispatcher (GenServer)
└── Scheduler (GenServer)     ← new
```

The Scheduler:
- Starts with no scheduled triggers
- Receives new `at` specs via `Scheduler.schedule/2` when policies are loaded
- Manages timers using `Process.send_after/3` (one-shot) and `:timer.send_interval/2` (repeating)
- When a timer fires, calls `Anemos.Runtime.dispatch/2` to push the `at` block's body as a synthetic event
- Repeating timers reschedule themselves after firing

### Synthetic events

When an `at` trigger fires, the scheduler dispatches a synthetic event named `AT_<label>` where `<label>` is derived from the time spec:
- `at 13:00` → `AT_13_00`
- `at interval(5min)` → `AT_INTERVAL_5min`
- `at 13:00 every day` → `AT_13_00`

Rules or conditions containing `at` blocks are compiled with subscriptions to these synthetic events. The scheduler is the event source — the dispatcher handles routing as usual.

### Compiled representation

The compiler produces a `%Anemos.CompiledSchedule{}` struct:

```elixir
%Anemos.CompiledSchedule{
  event_name: "AT_13_00",           # synthetic event to dispatch
  time_spec: {:time, {13, 0}},      # parsed time
  recurrence: :day,                 # nil | :day | :weekday | :weekend | :monday | ... | {:interval, ms}
  body: [ast_nodes],                # statements to execute (compiled into handler)
  context: "some.context"           # from enclosing rule/condition
}
```

### Time spec representations

| Source | Parsed form |
|--------|------------|
| `13:00` | `{:time, {13, 0}}` |
| `TIME_1300` | `{:time, {13, 0}}` |
| `DATE_2026.04.15` | `{:date, {2026, 4, 15}}` |
| `DAY_monday` | `{:day, :monday}` |
| `interval(5min)` | `{:interval, 300_000}` |

### Timer mechanics

**One-shot** (`at 13:00`):
1. Calculate milliseconds from now until next 13:00:00
2. `Process.send_after(self(), {:fire, event_name}, ms)`
3. On fire: dispatch event, do not reschedule

**Interval** (`at interval(5min)`):
1. `:timer.send_interval(300_000, {:fire, event_name})`
2. On fire: dispatch event (timer auto-repeats)

**Recurring at time** (`at 13:00 every day`):
1. Calculate ms until next 13:00:00
2. `Process.send_after(self(), {:fire_recurring, event_name, spec}, ms)`
3. On fire: dispatch event, calculate ms until next occurrence, reschedule

**Recurring on day** (`at 09:00 every monday`):
1. Calculate ms until next monday at 09:00:00
2. `Process.send_after(self(), {:fire_recurring, event_name, spec}, ms)`
3. On fire: dispatch event, schedule next week

**Weekday** (`at 13:00 every weekday`):
1. Calculate ms until next weekday (mon-fri) at 13:00:00
2. Same fire-and-reschedule pattern

### Lexer changes

New tokens needed:
- Time literal `HH:MM` — lexed as `{:time_literal, meta, {hour, minute}}`
- `TIME_HHMM` — lexed as `{:time_literal, meta, {hour, minute}}`
- `DATE_YYYY.MM.DD` — lexed as `{:date_literal, meta, {year, month, day}}`
- `DAY_weekday` — lexed as `{:day_literal, meta, weekday_atom}`
- `interval` — new keyword
- `every` — new keyword
- Weekday names (`monday`, `tuesday`, ..., `sunday`) — lexed as identifiers, recognized by parser
- `weekday`, `weekend` — lexed as identifiers, recognized by parser

### Parser changes

Add `parse_at/1` to handle:
```
"at" <time-spec> [ <guard> ] "{" <statement-list> "}"
```

`parse_at` is called from `parse_statement` and `parse_rule_body` (same places `parse_when` is called).

Returns `%AST.At{time_spec: time_spec, guard: nil, body: [...], line: line}`.

### Compiler changes

Add `compile_at_blocks/1` alongside `extract_when_blocks/1`. For rules, `at` blocks produce:
1. A `CompiledSchedule` that the scheduler uses to set timers
2. A `CompiledRule` subscribed to the synthetic `AT_*` event, with the `at` block's body as its handler

For conditions, `at` blocks work the same way — the condition subscribes to the `AT_*` event.

### Runtime integration

`Anemos.Runtime.load/2` currently passes compiled output to the dispatcher. After this change, it also passes `CompiledSchedule` specs to the scheduler:

```elixir
def load(name, source) do
  with {:ok, ast} <- Anemos.Parser.parse(source),
       {:ok, compiled} <- Anemos.Compiler.compile(ast) do
    Dispatcher.load(dispatcher_name(name), compiled)
    Scheduler.schedule(scheduler_name(name), compiled.schedules)
    :ok
  end
end
```

The `CompilationResult` struct gains a `schedules: []` field.

## Data flow

```
Policy loaded
  → Compiler extracts at blocks
  → Produces CompiledSchedule specs + CompiledRules subscribed to AT_* events
  → Scheduler receives specs, starts timers
  → Timer fires
  → Scheduler dispatches AT_* event into Runtime
  → Dispatcher routes to matching rules/conditions
  → Normal execution
```

## Testing strategy

- **Scheduler unit tests**: Use short intervals (10ms, 50ms) and `assert_receive` with timeouts
- **One-shot**: Schedule an `at` 50ms from now, verify it fires once
- **Interval**: Schedule `interval(50ms)`, verify it fires at least twice, cancel and verify it stops
- **Integration**: Load a policy with `at interval(100ms)`, verify the rule's body executes repeatedly
- **Time calculation**: Unit test the ms-until-next-occurrence functions directly with known inputs

## Edge cases

- `at 13:00` when it's already 13:00:05 → schedule for tomorrow 13:00:00
- `at DATE_2026.04.01` when that date has passed → do not schedule, log warning
- `at interval(0s)` → reject at compile time
- Multiple `at` blocks in the same rule → each gets its own timer and synthetic event
- Scheduler restart (supervisor restart) → all timers are re-created from stored specs

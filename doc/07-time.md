# 7. Time and duration

There are two different reasons to wait. “The door has remained open for five
minutes” depends on reports of a continuing state. “Check the door every five
minutes” depends only on a clock. Anemos expresses the first with a dwell
duration on `when`, and the second with an `at` schedule.

Both require a running interpreter. The command-line runner and `Anemos.run/2`
are one-shot tools; they are not services that stay alive to deliver future
timers. Use the supervised runtime from Chapter 9.

## A duration is an amount and a unit

Use compact suffixes with no intervening space:

| Unit | Meaning | Example |
| --- | --- | --- |
| `ms` | Milliseconds | `250ms` |
| `s` | Seconds | `30s` |
| `min` | Minutes | `5min` |
| `h` | Hours | `2h` |
| `d` | Days of 24 hours | `1d` |

The duration converter also recognizes the long names `seconds`, `minutes`,
`hours`, and `days`; use the compact spellings in source because tokenization
of the longer forms is not uniformly reliable. Amounts are whole numbers.
Durations are special trigger/schedule syntax, not a general arithmetic unit
system.

## Wait for a reported state to persist

```anemos
rule door-left-open {
  when DOOR_OPEN for 5min {
    log "Door has remained open for five minutes"
  }
}
```

The first truthy `DOOR_OPEN` report arms a timer. Repeated truthy reports do
not restart it. A falsey `state` report cancels it. If the deadline arrives
without cancellation, the body runs once. Continued true reports after that
do not repeatedly fire it; a false report must reset it before a new true
report can arm another dwell.

The host should dispatch both changes under the same event name:

```elixir
Anemos.Runtime.dispatch(:anemos, "DOOR_OPEN",
  %{context_data: %{"state" => true}})
# Later, if the door closes:
Anemos.Runtime.dispatch(:anemos, "DOOR_OPEN",
  %{context_data: %{"state" => false}})
```

Sending a different event called `DOOR_CLOSED` does not cancel the
`DOOR_OPEN` timer. A dwell assumes the last report continues to hold; it
cannot detect a failed sensor that simply stops reporting.

The timer uses the event context captured when it was armed. Do not assume
later true reports replace its payload. Its state belongs to the named rule
and trigger, not independently to every device that can reach that rule.
Give independent monitored entities independent state ownership.

Compound `AND`/`OR` triggers may have dwell durations too. The remembered
compound state determines whether the timer remains eligible. Use `for 0s`
for immediate behavior; it is compiled as no dwell. A condition's `when ...
for` duration is not implemented as a condition dwell timer; use a rule when
duration is essential.

## Run at a time or interval

```anemos
rule housekeeping {
  at interval(5min) {
    log "Periodic check"
  }
}
```

An interval repeats while the runtime is alive, with the first firing after
the interval. The default minimum interval is 1,000 milliseconds. A request
below that floor is rejected rather than silently slowed down.

```anemos
rule lunch {
  at 13:00 {
    log "Lunch"
  }
}
```

A bare clock time schedules a single future occurrence: today if that time
is still ahead, otherwise tomorrow. It is not automatically daily. For
recurrence, say so:

```anemos
rule calendar {
  at 09:00 every day { log "Morning" }
  at 11:00 every weekday { log "Standup" }
  at 09:30 every monday { log "Weekly planning" }
}
```

`weekday` means Monday through Friday. Named weekdays are lowercase. Valid
clock times use a two-digit hour and minute, `00:00` through `23:59`.
Invalid times can parse and still fail when the runtime tries to arm them;
always inspect load results.

## Dates and natural-language dates

Equivalent prefixed forms and relative dates are available:

```anemos
rule reminders {
  at TIME_1300 { log "At one o'clock" }
  at DATE_2099.04.15 { log "On the specified date" }
  at DAY_friday { log "At the next Friday" }
  at NLD_tomorrow { log "Tomorrow" }
  at NLD_next.wednesday { log "Next Wednesday" }
  at NLD_end.of.month { log "End of month" }
}
```

`DAY_friday` is a one-shot next-weekday occurrence, not a weekly recurrence.
The supported `NLD_` expressions are `today`, `tomorrow`, `yesterday`,
`next.monday` through `next.sunday`, `next.week`, `next.month`, `next.year`,
`end.of.month`, and `end.of.week`. They are resolved when a schedule is armed;
they are not a general natural-language parser. A resolution in the past,
including many uses of `today` or `yesterday`, is refused as inert.

Date and day forms target `00:00:01` on their date. Relative dates have these
targets:

| Expression | Target |
| --- | --- |
| `today`, `tomorrow`, `yesterday` | That day's `00:00:01` |
| `next.<weekday>` | Next occurrence, strictly after today, at `00:00:01` |
| `next.week` | Next Monday at `00:00:01` |
| `next.month` | First of next month at `00:00:01` |
| `next.year` | January 1 of next year at `00:00:01` |
| `end.of.month` | Last day of this month at `23:59:59` |
| `end.of.week` | Next Sunday at `23:59:59`; on Sunday, the following Sunday |

Calendar calculations use the machine's local naive date and time; there is
no per-policy time-zone setting. Do not infer daylight-saving, cross-zone, or
missed-run guarantees. If those guarantees matter, let an external scheduler
deliver a named event under a documented time-zone policy.

## Context and scheduled events

The built-in scheduler dispatches synthetic `AT_*` events with an empty
context. A context-scoped listener therefore refuses those events. An `at`
inside a scoped rule can load and arm successfully yet never reach its body.
For scoped timed work, have the host schedule an ordinary event and supply
the correct context, or use a deliberately unscoped scheduling rule whose
host operation has the appropriate authorization.

Schedules with identical specifications share one synthetic event and one
timer. Several listeners can consume that event. Different enclosing rule
names keep their action handlers distinct; recurrence is part of schedule
identity. Avoid duplicate identical `at` blocks in one named rule.

Each `at` body also has a generated handler name, distinct from its enclosing
rule's ordinary `when` handlers. Its `$` bindings therefore do not share the
ordinary rule's persistent state automatically. For timed work that must
consume the same event-driven state, have the host dispatch a scheduled
ordinary event to a `when` block in that rule.

## Observe scheduling failures

`Anemos.Runtime.load/3` returns `{:partial, failures}` if rules loaded but
one or more schedules could not be armed. A past date, unsupported relative
date, interval below the floor, or schedule cap can cause this. The failure's
`field` identifies the synthetic event. `Runtime.describe/1` reports loaded
schedules and their last firing times.

One-shot firing records and supported timer state survive scheduler/dispatcher
worker restarts within the runtime. They are not durable delivery records
across a VM restart. External effects are not guaranteed exactly once.

[Next: Datasets, queries, and facts](08-data.md) · [Contents](README.md)

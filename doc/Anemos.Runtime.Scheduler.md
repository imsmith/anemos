# `Anemos.Runtime.Scheduler`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/scheduler.ex#L1)

GenServer that manages time-triggered schedules.

Holds compiled `at` specs, manages timers via `Process.send_after/3` and
`:timer.send_interval/2`, and dispatches synthetic `AT_*` events into the
runtime when timers fire.

## Resource limits

Schedule specs come from policy text, which is not necessarily trusted.
Two limits bound what a policy can cost the runtime:

  * **Interval floor** (`:min_interval_ms`, default 1000). Every firing of
    an interval schedule becomes a synchronous dispatch through a single
    dispatcher process, so a `1ms` interval is a 1000 Hz loop that starves
    every other rule. Intervals below the floor are **rejected, not
    clamped**: silently running a schedule at a rate the policy did not ask
    for makes the runtime's behaviour diverge from its policy text with
    nothing to observe. Rejection tells the author their schedule is
    unrunnable; clamping does not.

  * **Schedule cap** (`:max_schedules`, default 1000) on the number of
    armed timers per scheduler, enforced cumulatively across calls.

Both default from application env (`:anemos`, `:min_schedule_interval_ms`
and `:max_schedules`) and may be overridden per scheduler at `start_link/1`.

## Schedules that cannot be armed

A past-dated schedule, an unresolvable natural-language date, or an
unrecognised duration unit yields a schedule that will never fire. These do
not report `:ok` — `schedule/2` returns `{:error, failures}` and logs a
warning for each. Arming is otherwise best-effort per spec: one bad entry
does not prevent the rest of the batch from being armed, since a batch is
the compiled output of a whole policy and discarding all of it for one bad
date would be worse than partial arming plus a loud report.

## One timer per event name

A schedule is identified by its `event_name`, and that name is the whole
of its identity here: the compiler derives it from the time spec alone, so
`at 08:00` in two unrelated rules — in two unrelated policy files —
produces two specs both named `AT_08_00`.

Arming both would be wrong twice over. The timers map is keyed by event
name, so the second `Map.put` used to displace the first entry while its
timer stayed armed: an uncancellable timer firing forever, dispatching an
event nothing in the map accounts for (A-19). And the fix is not to key
the map more finely, because the *event* is genuinely shared — one
`AT_08_00` dispatch already reaches every rule subscribed to `AT_08_00`.
Two timers would fire every such rule twice.

So arming an event name that is already armed **replaces** it: the
displaced timer is cancelled first, and the replacement does not consume
cap headroom. Re-loading the same policy is therefore idempotent with
respect to timers.

What this cannot fix from here: because the event name carries no rule
identity, the scheduler has no way to distinguish `at 08:00` in rule A
from `at 08:00` in rule B, and `unschedule/2` therefore disarms the time,
not the rule. That requires the compiler to derive schedule names from
rule identity as well as time spec.

# `failure_reason`

```elixir
@type failure_reason() ::
  {:interval_below_minimum, pos_integer(), pos_integer()}
  | {:schedule_limit_exceeded, pos_integer()}
  | {:date_in_past, {integer(), integer(), integer()}}
  | {:unresolvable_nld, String.t()}
  | {:nld_in_past, String.t()}
  | {:unknown_duration_unit, atom()}
  | {:invalid_duration, term()}
  | {:invalid_time_spec, term()}
```

Why a schedule spec could not be armed.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `fired_at`

```elixir
@spec fired_at(pid() | atom(), String.t()) :: DateTime.t() | nil
```

When the schedule `event_name` last fired, or nil.

# `forget`

```elixir
@spec forget(pid() | atom(), [String.t()]) :: :ok
```

Forgets that the named schedules fired, so a one-shot among them can arm again.

# `schedule`

```elixir
@spec schedule(pid() | atom(), [Anemos.CompiledSchedule.t()]) ::
  :ok | {:error, [Comn.Errors.ErrorStruct.t()]}
```

Adds schedule specs to the running scheduler. Timers start immediately.

Returns `:ok` when every spec was armed, or `{:error, failures}` where
`failures` is a `Comn.Errors.ErrorStruct` for each spec that was not: its `code` is
`anemos.scheduler/<reason>` and its `field` the schedule's event name.
Specs not named in `failures` were armed.

A spec whose `event_name` is already armed replaces it — see the moduledoc.

# `schedules`

```elixir
@spec schedules(pid() | atom()) :: [Anemos.CompiledSchedule.t()]
```

Returns the specs currently armed, one per event name.

# `start_link`

Starts the scheduler.

## Options

  * `:name` — process registration name (optional)
  * `:runtime_name` — the Anemos.Runtime name for dispatching events (required)
  * `:policy_store` — the runtime's `PolicyStore`; a scheduler given one
    arms every loaded schedule when it starts, so its own restart does
    not leave `at` blocks that never fire (optional)
  * `:state_table` — an `Anemos.Runtime.StateTable`. Each firing is
    recorded there, and a one-shot schedule that has fired is not armed
    again when the scheduler restarts or reconciles (optional)
  * `:dispatch_fn` — override dispatch function for testing (optional)
  * `:min_interval_ms` — interval floor (optional, see moduledoc)
  * `:max_schedules` — cap on armed timers (optional, see moduledoc)

# `sync`

```elixir
@spec sync(pid() | atom()) :: :ok | {:error, [Comn.Errors.ErrorStruct.t()]}
```

Makes what is armed match what is loaded: arms every schedule in the
policy store that is not armed, disarms every timer no loaded policy
declares, and leaves the rest running.

The policy store is read here, inside the scheduler, and not by the
caller. Two deploys finishing at once each call this after recording
themselves, so whichever call runs last sees both — a caller that computed
"arm this, disarm that" from its own view could disarm a time the other
had just picked up.

Answers like `schedule/2`, with a failure for every loaded spec that could
not be armed. A scheduler started without a `:policy_store` does nothing.

# `unschedule`

```elixir
@spec unschedule(pid() | atom(), [String.t()]) :: :ok
```

Disarms the timers for the named events and forgets their specs.

Idempotent: an event name that is not armed is skipped. This is the
counterpart `load/2` needed and did not have — without it, unloading a
policy left its `at` blocks firing indefinitely.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

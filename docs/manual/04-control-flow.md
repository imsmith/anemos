# 4. Decisions and control flow

An event selects a handler. Control flow decides how much of that handler is
evaluated and where work goes next. Start with ordinary branches; add guards
or handoffs when they make the policy's structure clearer.

## Branch on a value

```anemos
rule classify-temperature {
  when READING {
    if ?temperature >= 30 {
      log "hot"
    } elseif ?temperature >= 20 {
      log "comfortable"
    } else {
      log "cool"
    }
  }
}
```

The first true branch runs. Subsequent branches are skipped. A numeric
temperature of `32` logs only `"hot"`; `22` logs only `"comfortable"`.
`else if` is also accepted. `else` is optional. Blocks may contain nested
decisions and any supported handler statements.

When a branch needs a value later, decide whether it should be local to this
evaluation or retained for the next event. A `let` created only in one branch
will be absent on a path that never executes that branch. Prefer assigning
and consuming related values within the same branch.

## Stop a handler early

```anemos
rule accept-reading {
  when READING {
    if not exists ?temperature {
      log "Missing temperature"
      return
    }
    log ?temperature
  }
}
```

`return` and `done` both stop the current handler immediately, including when
they appear inside a loop or nested branch. Earlier queued operations and
`set` updates are retained. Other independent rules listening for the event
are still eligible to run.

Although `return <expression>` parses, the current evaluator discards the
expression rather than supplying a function return value. Use a host module
for value-returning computations, or an explicit handoff payload for another
rule. A query's `return ?name` is a different construct (Chapter 8).

`assert expression` is a useful related statement: it records whether an
expression held and stops this handler if it did not. A failed assertion is
an inspection result with `held: false`, not an ordinary module error. The
CLI's absence of operation errors is therefore not proof that every assertion
held. Inspect assertion results when using them as test expectations.

## Skip a trigger with `unless`

```anemos
rule notify-motion {
  when MOTION unless ?maintenance {
    log "Motion notification"
  }
}
```

The guard is evaluated afresh for every firing. If the maintenance field is
truthy, the body is skipped. A missing field is falsey, so the body runs.
Use typed booleans in the host payload; the string `"false"` suppresses this
rule just as any other nonempty string does.

`unless` also works on `if` and `at` blocks. On an `if`, a true guard skips
the whole construct, including its `else`. It does not choose the false branch.
Guards run before the body's local `let` bindings exist. Read event data or
previous persistent bindings there, not a value the body has yet to create.

## `until` and stopping permanently

`when EVENT until expression` is intended to disable a trigger after the
expression first becomes true. In the current runtime its latch is not
reliably preserved after a later successful handler evaluation. `until` on
`if` is ignored; it has no persistent branch lifetime. Do not rely on either
form for irreversible completion.

For a reliable run-once policy, make the state explicit:

```anemos
rule announce-once {
  when READY unless $announced {
    log "Ready for work"
    set announced = true
  }
}
```

Because `$announced` remains true, later `READY` events are skipped. This
means once per retained rule state, not once forever: replacing the declaration
with changed source or restarting the whole runtime resets it.

## Hand work to another event

```anemos
rule begin-job {
  when START {
    let destination = ?path
    nextevent PROCESS with { path: @destination, stage: "processing" }
    log "unreachable"
  }
}

rule process-job {
  when PROCESS {
    log ?path
    log ?stage
  }
}
```

`nextevent` stops the sending handler and redispatches the target event.
Current behavior broadcasts to **all matching rules**, including other named
rules. It is not confined to other `when` blocks in the sending rule.
Context filtering still applies, and the arriving context path is retained.

The optional `with` block resolves expressions in the sender's environment
and overlays its fields on the originating payload. Unmentioned fields
survive; a supplied field wins on a collision. The receiver reads `?path`
and `?stage`. `@destination` itself is not shared with the receiver.

Keys are simple names followed by a colon; use comma-separated pairs for
clarity. This block is a handoff argument form, not a general map literal.

## Hand work to a named rule

```anemos
rule start-audit {
  when START {
    nextrule audit-job with { message: "started" }
  }
}

rule audit-job {
  when AUDIT {
    log ?message
  }
}
```

`nextrule` selects by declaration name and invokes the target's compiled
handlers without requiring the incoming event to match their subscriptions.
A target with several `when` blocks can therefore run several handlers. Keep
handoff targets narrow when you want one action. The target still obeys its
context, guards, and dwell behavior. A missing target produces
`anemos.runtime/unknown_rule`.

Both handoffs increase dispatch depth. Cycles eventually hit the runtime's
recursion ceiling. Depth limiting prevents unbounded nested dispatch; it is
not a replacement for a termination condition in your policy.

## Choosing a control construct

Use `if` for a decision within one event. Use `unless` for a whole-trigger
exclusion. Use `return` or `done` for an early exit. Use `nextevent` when the
next stage is an event that any suitable listener may consume. Use `nextrule`
when you deliberately address a named policy component.

For application workflows that need durable steps, retries, or rollback,
provide those guarantees in host services. Anemos handoffs are immediate
in-process dispatch, not a persistent job queue.

[Next: Collections and pipelines](05-collections.md) · [Contents](README.md)

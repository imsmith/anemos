# 6. Conditions and capabilities

Some automation is about a change in a continuing situation rather than each
individual message. Other automation needs a named piece of work that is
requested explicitly. Conditions and capabilities give these ideas names.

## Combine reports in a rule

A compound trigger remembers the last report of each operand:

```anemos
rule ready-to-work {
  when (NETWORK_UP AND STORAGE_READY) {
    log "Both prerequisites are available"
  }
}
```

The operands start false. An arriving event reports true unless its payload
contains a `state` field whose value is boolean `false` or `nil`. A report
stands until another report of the same event replaces it. Missing `state`
means true; the string `"false"` means true too.

| Incoming report | Remembered network | Remembered storage | Body runs? |
| --- | --- | --- | --- |
| `NETWORK_UP`, no state field | true | false | No |
| `STORAGE_READY`, no state field | true | true | Yes |
| `NETWORK_UP`, `state: true` | true | true | Yes |
| `STORAGE_READY`, `state: false` | true | false | No |

A compound rule is evaluated on every operand report. It can run repeatedly
while the combined state is true. `OR` instead requires at least one true
remembered operand. Each listener keeps only reports admitted by its own
context. Use a single homogeneous `AND` or `OR` group; nested mixed event
algebra is not a general expression language for triggers.

A plain `when EVENT` means the event arrived. Do not expect a plain trigger
to filter a false `state` report the same way a compound state expression
does. Branch explicitly when a payload value matters.

## Name a continuing condition

If you want to react once when readiness becomes true, use a condition:

```anemos
condition ready {
  when (NETWORK_UP AND STORAGE_READY) {
    log "Readiness became true"
  }
}

rule start-work {
  when CONDITION_ready {
    log "Start the work"
  }
}
```

The condition begins false. On a false-to-true transition, it evaluates its
side-effect body and generates `CONDITION_ready`. A true-to-true evaluation
does neither. A report that makes the compound false resets the condition;
a later true transition can generate another notification.

In a persistent runtime, use `Anemos.Runtime.condition_state(runtime, "ready")`
to read its current boolean. `nil` means no condition of that name is loaded.
The DSL has no general built-in `?ready` lookup of condition state: `?name`
resolves context, queries, and datasets. Consume `CONDITION_ready`, or have
the host expose the current state when other rules need to read it.

## Predicates refine a condition

A top-level `if` in a condition is a predicate that must hold in addition to
the trigger:

```anemos
condition hot {
  when READING {
    log "Entered the hot state"
  }
  if ?temperature > 30 {}
}
```

Readings `29`, `31`, `32`, `28`, `33` cause two false-to-true transitions:
one at `31` and another at `33`. The top-level `if` body is not an additional
action block. Put transition actions inside the trigger body. An `if` nested
inside that body controls actions, not the condition's truth.

A condition with no `when` or `at` trigger cannot become true. Unrelated
events do not reset a condition. A single-event condition's truth is based
on its trigger and predicates, so use an explicit predicate if a report's
payload should turn it false. A compound condition uses remembered reports.

For predictable action selection, use one trigger body per condition. The
current compiler combines all `when`/`at` bodies into one transition body;
separate bodies are not independently selected by which trigger matched.
Condition guards are evaluated from event context, without persistent local
binding state. `until` there is a fresh exclusion test, not a permanent latch.

Conditions may declare a context just as rules do. Only admitted events
affect their reports and state. Generated transition dispatch retains the
originating event context, so a receiving rule must also be reachable there.

## Define work to perform on demand

```anemos
capability audit-request {
  context building
  on demand {
    log ?request_id
  }
}

rule process-request {
  context building.garage
  when REQUEST {
    demand audit-request
    log "Request received"
  }
}
```

A capability is passive until demanded. Its `on demand` body can read event
data. Its declared context restricts who may demand it: the **demanding
declaration's** context must lie inside the capability's context. In this
example `building.garage` is inside `building`. A caller event arriving from
`building.garage.sensor` does not rescue a demanding rule that declares no
context; the rule itself must present an eligible scope.

An unscoped capability can be demanded from any scope. A nonexistent capability
and a context denial are errors under every demand flag, including `--optional`.
Optional means tolerance of execution failure, not tolerance of a misspelled
name or a crossed boundary.

## Demand flags and the current integration limit

The demand evaluator defines a stack protocol:

| Flag | Stack meaning |
| --- | --- |
| Bare or `--requisite` | Failure ends the stack immediately |
| `--required` | Remember failure and evaluate the remaining stack |
| `--optional` | Tolerate execution failure |
| `--sufficient` | Success ends the stack successfully |

However, **policy dispatch currently evaluates each `demand` statement as its
own one-element stack**. A failed demand appears in the operation results;
it does not stop later queued commands or demands. `--sufficient` does not
skip later policy statements. The distinction between `--required` and
`--requisite` therefore does not create a multi-statement gate in a rule.

There is a second limit: standalone operations returned by a capability body
are reported, but are not recursively executed by the demand path. An
expression-position host call inside that body executes while the body is
evaluated. A standalone `[MODULE::verb ...]` inside it is only a returned
operation descriptor on this path. A body error operation is likewise not
the same as a failed stack result.

These limits make `demand` unsuitable as a security gate in this version.
For an actual authorization decision, have a host verb return a boolean,
bind it, and branch before producing protected operations:

```anemos
rule authorized-request {
  when REQUEST {
    let allowed = [AUTH::allowed ?principal]
    if @allowed == true {
      [WORK::perform ?job]
    }
  }
}
```

The host supplies `AUTH` and `WORK`. A failed value-position authorization
call aborts evaluation, and only boolean `true` takes the branch. This makes
the required decision explicit without depending on incomplete stack wiring.

## Exercise

Send `A=true`, `B=true`, `A=true`, `B=false`, `B=true` to both a rule with
`when (A AND B)` and a condition with that trigger. How often does each act?

Answer: the rule acts three times (reports 2, 3, and 5). The condition
transitions to true twice (reports 2 and 5).

[Next: Time and duration](07-time.md) · [Contents](README.md)

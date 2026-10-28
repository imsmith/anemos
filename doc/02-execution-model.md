# 2. How policies run

Knowing a language's syntax tells you what you can write. Knowing its execution
model tells you what the program will do. In Anemos, the important questions
are which listeners receive an event, which state they share, and when an
expression actually invokes host code.

## From text to a running policy

The host loads source text. The load boundary checks its size and authority,
the parser recognizes declarations, and the compiler builds executable
handlers. The runtime installs those handlers, datasets, and schedules.
Loading a rule does not execute its `when` body.

An incoming event supplies an exact name, an optional context path, and a
payload. The dispatcher finds subscribers, filters them by context, evaluates
the eligible handlers, and executes the operations they produce. Conditions
also receive events they subscribe to and may generate transition events.

An event can reach several rules. Rules are listeners rather than an
exclusive chain of alternatives. If two rules subscribe to `MOTION`, both
eligible rules can run. Use `if`/`elseif`/`else` within a handler when you want
mutually exclusive choices. Do not make correctness depend on one independent
listener having run before another.

## The four kinds of name

Most policy mistakes become easier to see when names are classified:

| Name | Example | Who supplies it? |
| --- | --- | --- |
| Declaration | `garage-motion` | The policy author |
| Event | `MOTION`, `SENSOR::motion` | The event producer and policy agree |
| Module and verb | `DEVICE::set` | The host registers the implementation |
| Binding | `?visitor`, `@message`, `$count` | Event data or policy evaluation |

`when SENSOR::motion` subscribes to that event name. It does not call the
`SENSOR` module. `[SENSOR::motion]` is a command and does call a module. The
brackets distinguish an action from a subscription.

## A context belongs to a listener

Declare one context boundary per rule. Either of these forms expresses it:

```anemos
rule listen {
  context "building.garage" {
    when MOTION { log "heard" }
  }
}
```

```anemos
rule listen {
  context building.garage
  when MOTION { log "heard" }
}
```

The latter form is convenient in longer definitions. Use a single path rather
than several apparently independent context blocks: the compiler extracts one
context for the declaration, not a separate access domain for every block.
Nested contexts do not provide lexical path composition.

For a boundary `building.garage`:

| Arriving context | Admitted? |
| --- | --- |
| `building.garage` | Yes |
| `building.garage.sensor` | Yes |
| `building` | No |
| `building.garden` | No |
| `building.garageband` | No |
| Absent | No |

A rule with no context boundary accepts any arriving context, including an
absent one. The host is responsible for authenticating the path it places on
events. The language's comparison does not establish who sent an event.

## State has a lifetime and an owner

There are three ways to read values:

| Read | Meaning | Lifetime |
| --- | --- | --- |
| `?name` | External/name resolution | Current event plus visible queries/datasets |
| `@name` | A `let` or loop binding | Current handler evaluation |
| `$name` | A `set` binding | Retained for this named rule across events |

Several `when` blocks in the same named rule can communicate through `set`.
Different named rules have separate binding state. That state is not
automatically divided by sensor, user, or arriving context. If two devices
reach the same rule, they reach the same `$count`. To maintain per-device
state, arrange separate rule identities or keep keyed state in a host module.

This counter initializes lazily and then increments:

```anemos
rule count-motion {
  when MOTION {
    if not exists $count {
      set count = 0
    }
    set count = $count + 1
    log $count
  }
  when RESET {
    set count = 0
  }
}
```

In one persistent runtime, `MOTION`, `MOTION`, `RESET`, `MOTION` logs
`1`, `2`, and `1`. `RESET` logs nothing. Repeating `Anemos.run/2` four times
cannot reproduce this sequence because each call creates fresh state.

Persistent here means retained in a running runtime. State survives supported
worker restarts, but is not an on-disk database and does not survive loss of
the whole runtime or VM. Chapter 10 explains replacement and recovery.

## Bodies evaluate, then operations execute

This distinction matters whenever host commands have side effects.

A standalone command statement produces an operation for the dispatcher to
execute after evaluating the handler. A command in an expression must supply
a value immediately, so it invokes the host while the expression is evaluated.

```anemos
rule demonstrate-order {
  when GO {
    [AUDIT::record "statement"]
    let answer = [LOOKUP::read "value"]
    log @answer
  }
}
```

Here `LOOKUP::read` runs while the handler is being evaluated. Only afterward
does the dispatcher execute the queued `AUDIT::record` operation and log the
answer. The source order alone is therefore not the order of all external
side effects. These modules are illustrative host implementations, not bundled
services.

When sequencing host calls is essential, express the sequence through value
bindings whose calls are evaluated in order, or provide a host verb that owns
the whole operation. Do not treat a sequence of independent statements as a
transaction.

A failed value-position call aborts the rest of that handler's evaluation and
reports an error. Previously evaluated calls and earlier queued operations
are not rolled back. Errors returned by queued operations do not, in general,
cancel later queued operations. This is especially relevant to `demand`.

## Put executable statements inside triggers

Rules are compiled from their `when` and `at` blocks. A top-level `set` or
`log` in a rule is not a rule initializer, even where the parser accepts it.
Place initialization inside a handler, guarded by `exists` as in the counter.
Inline `data` and `query` declarations are an exception: they are definitions
installed at load time, not executable statements.

## Exercise: who owns the count?

Give `count-motion` a context of `garage`, then send motion from
`garage.north` followed by `garage.south`. What does it log?

Answer: `1`, then `2`. Both paths are admitted to the same named rule.
Context filtering changes reachability; it does not allocate independent
copies of persistent bindings.

[Next: Values and expressions](03-values-and-expressions.md) · [Contents](README.md)

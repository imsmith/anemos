# 5. Collections and pipelines

Batch work brings two questions: how to perform an action for every item, and
how to turn a collection into another value. Loops answer the first question;
pipelines are often clearer for the second.

The examples below receive lists from the host API. CLI `--context-data`
cannot construct a typed list from a string.

## Iterate with `for`

```anemos
rule print-items {
  when BATCH {
    for item in ?items {
      log @item
    }
  }
}
```

Given `%{"items" => ["alpha", "beta"]}`, this logs `"alpha"`, then
`"beta"`. The loop variable is an `@` binding. Each iteration replaces that
temporary binding, and the evaluator removes it after the iteration. Avoid
reusing the name of an outer `let`; the current loop cleanup does not restore
an outer binding of the same name.

`set` changes inside the loop survive into the next iteration and the next
event. A local binding with another name can also pass through the loop's
evaluation; braces do not create general-purpose lexical scopes. Choose loop
variables that make their role and lifetime obvious.

A missing iterable yields no iterations. A non-list value is wrapped as a
single item. Maps and sets are not automatically traversed as collections of
entries: have the host return a list when you intend item-by-item work.

There is no `break` or `continue`. A `return` inside the loop exits the whole
handler. To skip an item, guard that iteration's work with an `if`.

## Loop aliases

`each item in ?items { ... }` and `every item in ?items { ... }` are aliases
for explicit `for` iteration. The shorter forms `each item { ... }` and
`every item { ... }` parse but currently have no iterable, so they perform
no work. They do not infer a payload field. Always give an explicit source.

`foreach FILE::list { ... }` invokes the module verb and iterates its returned
list as `@item`. The module must be registered. Prefer explicit `for item in
[FILE::list]` when you need to see the collection expression directly.

## Repeat with `while`

```anemos
rule countdown {
  when START {
    set remaining = 3
    while $remaining > 0 {
      log $remaining
      set remaining = $remaining - 1
    }
    log "finished"
  }
}
```

This logs `3`, `2`, `1`, and `"finished"`. The condition is evaluated before
each iteration. Ensure the body changes something that makes it false.
The interpreter stops repeating at 10,000 iterations; hitting that safety
limit is not a useful successful outcome. Bound the work yourself.

For a known collection, use `for`. It describes intent more directly and
avoids a counter whose only job is controlling a loop.

## Fan out with `with`

`with each <name> in <expression> { ... }` runs the body once per element,
like `each`, but the branches are evaluated concurrently. `with { ... }`
runs each statement of its block as its own branch. The operations come
back in source order either way, so the only difference from a loop is
that slow host calls in expression position overlap.

```anemos
rule all-off {
  when NIGHT {
    with each light in ("porch" "garage" "hall") {
      [DEVICE::set @light "off"]
    }
  }
}
```

A branch cannot `set`: concurrent writes to one persistent binding have no
defined winner, so the parser refuses it. `done`, `return` or an error in a
branch stops the body at that branch, with the branches before it kept. A
branch that runs past four seconds is stopped with a `with_timeout` error.
The spec's `with agents [...]` and `with <group> tagged "..."` forms are
refused, because the runtime keeps no agents or tags to fan out over.

## Filter, map, reduce

The pipe operator `|>` passes the value on its left into the stage on its
right. A pipeline is an expression; bind or log its answer.

```anemos
rule summarize {
  when BATCH {
    let total = ?values
      |> filter ?n (?n > 0)
      |> map ?n (?n * 2)
      |> reduce sum 0 ?n ($sum + ?n)
    log @total
  }
}
```

For `[-1, 2, -3, 4, 5]`, follow the values through the stages:

| Stage | Answer |
| --- | --- |
| Input | `[-1, 2, -3, 4, 5]` |
| `filter` | `[2, 4, 5]` |
| `map` | `[4, 8, 10]` |
| `reduce` | `22` |

`filter ?n (predicate)` evaluates its predicate with the current element
available as `?n`. It retains elements whose predicates are truthy.
`map ?n (expression)` replaces each element with the expression's answer.
These variables are `?` references, unlike a `for` loop's `@item`.

`reduce sum 0 ?n (expression)` starts an accumulator called `sum` at `0`.
For each element, the body reads the current accumulator as `$sum` and the
element as `?n`, then returns the next accumulator. This accumulator belongs
to the reduction. It does not by itself create persistent rule state named
`sum`.

Empty-list filtering and mapping return an empty list. Reducing an empty
list returns the initial accumulator. The collection built-ins wrap a scalar
as a singleton list and treat missing `nil` as an empty list.

## Pass a collection to a host command

```anemos
rule submit-batch {
  when BATCH {
    let accepted = ?values |> filter ?n (?n > 0)
    let receipt = @accepted |> [QUEUE::submit "normal"]
    log @receipt
  }
}
```

The pipeline prepends its collection to the explicit command arguments.
`QUEUE::submit` receives `[accepted_list, "normal"]`; it is called once
for the collection, not once per element. Its returned value becomes the
pipeline answer. `QUEUE` is supplied by the host.

The parser also accepts `|> emit [MODULE::verb ...]`. In this version that
form constructs descriptors that are discarded rather than reliably
dispatching one operation per item. Use an explicit `for` loop with a command
statement for side effects:

```anemos
rule submit-each {
  when BATCH {
    for item in ?items {
      [QUEUE::submit @item "normal"]
    }
  }
}
```

Remember the operation model from Chapter 2: these standalone commands are
queued during handler evaluation, then executed. A host verb used inside a
pipeline expression runs during evaluation.

## Exercise

Change the summarizing pipeline to retain values greater than `2`, then
multiply by `3` and reduce from `10`. What does the same input produce?

Answer: `[4, 5]` becomes `[12, 15]`, which reduces from `10` to `37`.

[Next: Conditions and capabilities](06-conditions-and-capabilities.md) · [Contents](README.md)

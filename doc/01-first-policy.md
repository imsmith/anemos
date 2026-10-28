# 1. Your first policy

Suppose a motion sensor reports activity in a garage. You want to write down
what should happen when that report arrives. In Anemos, that instruction is a
*rule*. One or more declarations saved together form a *policy*.

We will start by writing to the log. This lets us learn the language without
installing a sensor or connecting a device controller. Later we will replace
the log statement with a command supplied by the application.

## Prepare the interpreter

Use a checkout of this repository. Its `.tool-versions` specifies Erlang
29.1.2 and Elixir 1.20.4 for OTP 29; `mix.exs` requires Elixir `~> 1.20`.
Install that toolchain using your usual environment manager and confirm that
`elixir` and `mix` are on your terminal's path:

```sh
elixir --version
mix --version
mix deps.get
mix compile
```

Mix is Elixir's build and task runner. You do not need to learn Elixir to use
the policy runner. Dependencies are fetched from the declarations and lockfile
in this checkout; a sibling checkout of `comn` is not needed.

## Read a complete rule

The file [hello.rule](examples/hello.rule) contains:

```anemos
rule welcome {
  when MOTION {
    log "Motion detected"
  }
}
```

`rule` introduces a declaration. `welcome` is the name we give it. The outer
braces contain its definition. `when MOTION` subscribes to an event named
`MOTION`; the inner braces contain the statements to evaluate when that event
arrives. `log` records a value. Double quotes delimit a string.

Whitespace makes this structure readable. A semicolon starts a comment; it
does not terminate a statement. A line beginning with `#` is also a comment.

Run the file:

```sh
mix anemos.run docs/manual/examples/hello.rule --event MOTION
```

The runner prints the file it parsed, a dispatch summary, and an operation
line containing:

```text
log "Motion detected"
```

You may also see a timestamped Logger message. That is the log operation
being executed; the runner's operation line is its report of the work.

Now change `--event MOTION` to `--event RAIN`. No rule subscribes to `RAIN`,
so the runner reports that no rule subscribes. Anemos does not guess which
event you intended. Event names are case-sensitive, exact strings.

## Give the event some data

An event can bring a payload: values such as the sensor name, measured
temperature, or person making a request. Read a payload field with `?name`.
The question mark means “resolve this name from the data available to me.”

```anemos
rule greet {
  when ARRIVAL {
    log ?visitor
    if ?visitor == "Ada" {
      log "Welcome back"
    } else {
      log "Welcome"
    }
  }
}
```

Save this as `greet.rule`, or use [the supplied file](examples/greet.rule):

```sh
mix anemos.run docs/manual/examples/greet.rule \
  --event ARRIVAL --context-data visitor=Ada
```

The log values are `"Ada"` and `"Welcome back"`. Try `visitor=Grace` and
the second value becomes `"Welcome"`.

Repeat `--context-data` to supply more fields. CLI values are **strings**:
`--context-data enabled=false` supplies `"false"`, not the boolean `false`.
The string is truthy. When you need numbers, booleans, lists, or maps, use the
host API introduced below or the persistent examples in Chapter 9.

If a field is missing, `?visitor` ordinarily resolves to `nil`, the host's
missing-value representation. Anemos has no `nil` literal. To test for a
present value, write `exists ?visitor`; to accept only a particular value,
compare it explicitly as we did above.

## Limit a listener to a context

A context is a dotted path describing where an event is admitted. In
[garage.rule](examples/garage.rule), our listener belongs to `garage`:

```anemos
rule garage-motion {
  context "garage" {
    when MOTION {
      log "Garage motion detected"
    }
  }
}
```

```sh
mix anemos.run docs/manual/examples/garage.rule \
  --event MOTION --context garage.sensor
```

The rule runs because `garage.sensor` is inside `garage`. `garage` itself is
also admitted. `garden.sensor` and `garageband.sensor` are not. A missing
`--context` is refused by this listener too: the caller must say where it
stands when a boundary has been declared.

`--context` and `--context-data` answer different questions. The first is
the caller's path. The second is its payload. A payload field called
`context` does not move an event across a boundary.

## Ask the host to do something

Commands use square brackets and a module-qualified verb:

```anemos
rule garage-lights {
  context "garage" {
    when MOTION {
      [DEVICE::set "garage.lights" "on"]
    }
  }
}
```

`DEVICE` names a registered module; `set` names one of its verbs. The two
strings are its arguments. The built-in development `DEVICE` module used by
the one-shot runner computes an answer in memory. It does not turn on a real
light. A deployed application must register its own device implementation.

This separation lets the same policy language work with different systems.
A rule specifies the action; the host decides how that action is implemented.

## Run a policy from Elixir

For a single event, start an interactive session with `iex -S mix`, then enter:

```elixir
source = File.read!("docs/manual/examples/greet.rule")
{:ok, results} = Anemos.run(source,
  event: "ARRIVAL",
  context_data: %{"visitor" => "Ada"})
Enum.map(results, &Map.get(&1, :value))
# => ["Ada", "Welcome back"]
```

`Anemos.run/2` builds a temporary interpreter, dispatches one event, and tears
the interpreter down. A second call starts fresh. For state across events or
scheduled work, use a persistent `Anemos.Runtime` (Chapter 9).

The outer `{:ok, results}` says dispatch completed. Individual results may
still contain `{:error, reason}`. We will learn to inspect those in Chapter 11.

## Exercises

1. In `greet.rule`, add a second `log ?visitor` after the `if`. How many log
   values will an arrival produce?
2. Run `garage.rule` with `--context garageband`. Does the shared prefix help?
3. Replace the string comparison in `greet.rule` with `if ?visitor`. What does
   `--context-data visitor=false` do?

Answers: (1) Three: visitor, greeting, visitor. (2) No; paths compare whole
segments. (3) It takes the true branch because `"false"` is a string. Only
boolean `false` and `nil` are falsey.

[Next: How policies run](02-execution-model.md) · [Contents](README.md)

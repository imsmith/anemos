# Anemos — Usability Analysis

Forensic review of the user-facing surface. Analysis date: 2026-08-06, commit `80ba1b4`.

## 0. Scope adaptation

Anemos has **no GUI**. There are no routes, views, components, state atoms,
WebSocket subscriptions, or ARIA attributes anywhere in the tree. The
`arch/diagrams/component-frontend-as-built.c4` file uses "frontend" in the
compiler sense — lexer, parser, AST, compiler — not the web sense.

The user-facing surface is therefore:

| Nominal section | Actual subject |
|---|---|
| Application structure | Language surface syntax and declaration forms |
| Core workflows | Author → parse → compile → dispatch; embed as a library |
| UI components | Language constructs and the `Anemos.Module` extension point |
| State management | Variable sigils, `set` persistence, condition/context stores |
| Error handling UX | Lexer, parser, compiler, and runtime diagnostics |
| Configuration | Runtime registration APIs, CLI flags |
| Internationalization | (none — see §7) |
| Real-time updates | Event dispatch, dwell timers, scheduler |
| Accessibility | Discoverability, learnability, docs |
| Known problems | §10 |

Every claim below was verified by executing the code, not by reading it alone.

---

## 1. Application structure — the language surface

### Top-level declarations

Three, all block-structured and mutually consistent:

```text
rule <name> { ... }
condition <name> { ... }
capability <name> { ... }
```

Inside each: an optional `context`, then trigger blocks (`when`, `at`,
`on demand`), then statements. The nesting is regular and reads well:

```text
rule garage-lights-on {
  context "garage.motion.sensor" {
    when SENSOR_MOTION_DETECTED {
      [DEVICE::set "garage.lights" "on"]
    }
  }
}
```

This is the language's strongest property. `parse_declaration`
(`lib/anemos/parser.ex:122`) dispatches on exactly these three keywords, and the
error for anything else names them.

### Statement vocabulary

`let`, `set`, `log`, `emit`, `demand`, `if`/`elseif`/`else`, `while`, `for`,
`each`, `every`, `foreach`, `return`, `done`, `nextevent`, `nextrule`,
`[MODULE::verb ...]` commands, triple patterns, `data`/`query` blocks, and
`|>` pipelines. The parser is 1,946 lines and the compiler 911; the surface is
large for a v0.1.0.

### Navigation between "screens"

There is one path in and one path out. In: a `.rule` source string. Out: a list
of operation maps. Everything else is the runtime's internal wiring.

---

## 2. Core workflows

### Workflow A — try the language (CLI)

```bash
mix anemos.run priv/examples/garage-lights.rule --event SENSOR_MOTION_DETECTED
```

Verified output:

```text
Parsing priv/examples/garage-lights.rule...
Dispatched SENSOR_MOTION_DETECTED -- 1 operation(s):

  [DEVICE::set "garage.lights" "on"]
```

This works and is genuinely pleasant. It is also the **only** one of the three
shipped examples that produces a satisfying result — see §10.1.

The task is 66 lines (`lib/mix/tasks/anemos.run.ex`) and supports exactly two
inputs: a file path and `--event`. There is no `--context`, no `--dry-run`, no
`--ast`, no `--check`. A user who wants to know "does this file parse?" must
dispatch a fake event and interpret "No rules matched" as success.

### Workflow B — explore interactively (Livebook)

`notebooks/playground.livemd` is 488 lines and is the best documentation
artifact in the repository. It walks lexer → parser → compiler → dispatcher with
runnable cells, then covers garage lights, conditions, capabilities, demand
flags, variable sigils, the full ddns example, the supervised runtime,
scheduled triggers, NLD dates, loops, and flow control, ending in a sandbox
cell.

Gaps: no section for guards (`unless`/`until`), triple patterns, pipelines, or
`data`/`query` blocks, all of which are implemented and documented in the
README.

### Workflow C — embed the interpreter (the real product)

```elixir
children = [{Anemos.Runtime, name: :anemos}]
Anemos.Runtime.register(:anemos, "DEVICE", MyApp.Device)
Anemos.Runtime.load(:anemos, File.read!("policies/garage.rule"))
{:ok, results} = Anemos.Runtime.dispatch(:anemos, "SENSOR_MOTION_DETECTED")
```

This is a clean, well-shaped API: blank runtime, everything loads dynamically,
declarations accumulate. `register/2` (name derived from the `Anemos.Module`
macro) and `register/3` (explicit name) both exist
(`lib/anemos/runtime.ex:83,89`), matching both README spellings.

### Workflow D — extend with a module

```elixir
defmodule MyApp.Anemos.Secret do
  use Anemos.Module, name: "SECRET"
  verb :unlock, &Comn.Secret.unlock/2
end
```

Declarative, minimal ceremony, well documented. The best extension point in the
system.

---

## 3. "Components" — language construct inventory

| Construct | Purpose | Notable |
|---|---|---|
| `rule` | Event-triggered handler | Only construct with dwell timers |
| `condition` | Stateful GenServer, false→true broadcast | Emits synthetic `CONDITION_<name>` |
| `capability` | Passive named action | Invoked only via `demand` |
| `context` | Exclusionary listener-side filter | Prefix match, see §3.1 |
| `when` | Event trigger; supports `OR`/`AND`, `for <dur>` | |
| `at` | Clock trigger; times, intervals, recurrence, NLD | |
| `on demand` | Capability body | |
| `let` / `set` | Bind `@ephemeral` / `$persistent` | See §4 — sigils are a trap |
| `demand` | Invoke capability with PAM flags | `--required`, `--optional`, `--sufficient`, `--requisite` |
| `emit` | Produce output, optional type/destination/label | Labelled emits re-dispatch |
| `[MODULE::verb args]` | External call | Runtime-resolved, never compile-checked |
| Triple patterns | RDF assert (`->`) and query (spaces) | Two syntaxes, one bracket form |
| Loops / flow control | `while`, `for`, `each`, `every`, `foreach`; `return`, `done`, `nextevent`, `nextrule` | |
| Guards | `unless` (stateless), `until` (stateful, permanent) | |

### 3.1 Context matching is looser than documented

The README calls context "an exclusionary boundary." The implementation
(`lib/anemos/runtime/dispatcher.ex:443-450`):

```elixir
defp context_matches?(_rule, nil), do: true

defp context_matches?(rule, event_context) do
  case get_in(rule, [Access.key(:meta), :context_path]) do
    nil -> true
    rule_context -> String.starts_with?(event_context, rule_context)
  end
end
```

An event dispatched with **no** context path matches every rule regardless of
its declared context. So `context "garage.motion.sensor"` provides no isolation
at all under the CLI, which never sets a context path. The boundary is opt-in
from the event side, which is the opposite of what "exclusionary" implies.

It is also a raw `String.starts_with?` on the whole path, so context
`"garage"` matches event context `"garagedoor.sensor"` — no segment boundary
check.

---

## 4. State management — sigils are the single largest usability defect

The README documents the model clearly and correctly:

| Sigil | Meaning | Created by |
|---|---|---|
| `?name` | Dereference from external context data | Environment |
| `@name` | Immutable, ephemeral | `let` |
| `$name` | Mutable, persistent | `set` |

> "The keyword determines the kind: `let fqdn = ?fqdn` creates `@fqdn`. The
> sigil is how you read it back."

The compiler implements exactly this — `let` writes the `{:let, name}` key,
`set` writes `{:set, name}`, and `@`/`$` read their respective namespaces
(`lib/anemos/compiler.ex:579,590,744,750`).

**The problem is what happens when you get it wrong.** Verified by execution:

```text
[let a = 42, read with @a]  => {:ok, [%{type: :log, value: 42}]}
[let a = 42, read with $a]  => {:ok, [%{type: :log, value: nil}]}
[log @nosuchvar]            => {:ok, [%{type: :log, value: nil}]}
[log ?nosuchvar]            => {:ok, [%{type: :log, value: nil}]}
```

`Map.get/2` with no default. Every unbound variable — wrong sigil, typo, or
genuinely absent context data — silently resolves to `nil`, logs an empty line,
and reports success. There is no warning, no error, no distinction between
"you meant a different sigil" and "the environment did not supply this."

This is not hypothetical. **A shipped example has the bug.**
`priv/examples/normalize-pdfs.rule:9-12`:

```text
let title = [PDF::title]
let meta_title = [PDF::metadata title]

if $title ne $meta_title {
```

`let` binds `@title`; the comparison reads `$title`. Both are `nil`. `nil ne
nil` is false, so the branch is dead. Nobody noticed because nothing complained.

Consequence for the mental model: because `let`+`@` and `set`+`$` must be kept
in sync by the author with zero enforcement, the "sigil is how you read it back"
rule is a memorization burden with a silent failure mode — precisely the
opposite of the project's own stated design principle #6.

### Persistence mechanisms

- `$` bindings survive across event firings, held in dispatcher state
  (`lib/anemos/compiler.ex:510` filters `{:set, _}` keys for persistence).
- `ContextStore` (Agent) holds `?` resolution data, set via
  `Anemos.Runtime.put_context/3`.
- `TripleStore` (Agent) accumulates asserted facts.
- `DataStore` holds `data`/`query` block results.
- Conditions hold boolean state in per-condition GenServers.
- Dwell timers hold `:listening`/`:armed` state keyed per rule
  (`lib/anemos/runtime/dispatcher.ex:297-319`).

Nothing is persisted to disk. A runtime restart loses all `$` bindings, all
triples, and all condition state. This is undocumented — the README says `$`
"survives across firings" without saying it does not survive a restart.

---

## 5. Error handling UX

This is where the project diverges hardest from its own intentions.
`docs/design-notes/language-ergonomics.md`, principle 6:

> **Forgiving, Discoverable Errors.** Error messages should suggest
> corrections. Users should safely guess syntax. The parser should guide users
> toward correct patterns.

### 5.1 Measured parser error quality

Fourteen malformed inputs, actual output:

| Input | Message |
|---|---|
| Missing closing brace | `Unexpected end of input, expected statement` |
| Missing rule name | `Expected rule name (identifier) but got lbrace on line 1` |
| Typo `whne` for `when` | `Unexpected token identifier on line 2, expected statement` |
| Unterminated string | `Lexer error on line 3: expected end of string near "\"unclosed]\n  }\n}"` |
| Lowercase module `device::set` | `Expected MODULE::verb or triple pattern on line 3` |
| Missing `::` | `Expected MODULE::verb or triple pattern on line 3` |
| Stray `%%%` on line 7 | `Unexpected token operator on line 7, expected statement` |
| Empty file | **parses OK** |
| Whitespace only | **parses OK** |
| `for 10 min` (space in duration) | `Expected lbrace but got keyword on line 2` |
| `widget foo { }` | `Expected declaration (rule, condition, ...) but got identifier on line 1` |
| `if` without brace | `Expected lbrace but got lbracket on line 4` |
| Unbalanced paren in `when` | `Unexpected token in compound event on line 2` |

Six distinct failures against principle 6:

1. **Internal token names leak to end users.** `lbrace`, `lbracket`, `rbrace`,
   `keyword`, `identifier`, `operator`. A policy author writing `.rule` files
   has never seen these terms. "Expected lbrace but got keyword" is a message
   for a parser author.

2. **The token's *value* is never shown.** "Unexpected token operator on line 7"
   does not say which operator. The user must eyeball the line.

3. **No column, contradicting `CLAUDE.md`.** The project convention states
   "Parser errors include line/col position." The lexer computes a column and
   returns it — then the parser discards it at `lib/anemos/parser.ex:61`:

   ```elixir
   {:error, message, line, _col} ->
     {:error, "Lexer error on line #{line}: #{message}"}
   ```

   Tokens carry only `[line: line]` (`lib/anemos/lexer.ex:426` and every
   sibling clause). Column information does not exist downstream of the lexer.

4. **No source excerpt or caret.** Nothing echoes the offending line.

5. **The most common beginner error gets the worst message.** An unbalanced
   brace yields `Unexpected end of input, expected statement` — no line number
   at all, and no indication of where the unclosed block started. On a
   200-line policy file this is close to useless.

6. **No suggestions, ever.** `whne` → generic. `device::set` → generic. There is
   no edit-distance check, no "did you mean", no listing of valid alternatives
   beyond the one top-level message that names `(rule, condition, ...)`.

The lexer is measurably better than the parser: its errors include a 20-character
source snippet (`lib/anemos/lexer.ex:397,400`), which is the one place a user
gets to see their own text.

### 5.2 There is essentially no compile-time checking

The entire compiler has **one** diagnostic (`lib/anemos/compiler.ex:449`):

```elixir
throw({:compile_error, "for <duration>: zero duration not allowed"})
```

No semantic validation pass exists. Not checked at compile time:

- Unknown modules — deferred to runtime, per invocation
- Unknown verbs — deferred to runtime
- Unknown capabilities in `demand` — deferred to runtime
- Undefined variables — never checked, resolve to `nil`
- Sigil/keyword mismatch — never checked
- Duplicate declaration names — never checked (see below)
- `nextrule` targets that do not exist — never checked

A policy file can be entirely wrong and compile cleanly.

### 5.3 Three incompatible runtime error shapes

Verified:

```text
unknown module    => {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/unknown_module", ...}}
unknown verb      => {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/unknown_verb", ...}}
missing capability=> {:error, {:unknown_capability, "nosuchcap"}}
arithmetic on nil => {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/handler_crash",
                       message: "Rule r raised: \"bad argument in arithmetic expression\""}}
```

`demand` on a missing capability returns a bare tuple, bypassing the
`Anemos.Runtime.Errors` registry entirely. Any consumer pattern-matching on
`%Comn.Errors.ErrorStruct{}` will miss it.

The `ErrorStruct` carries a `suggestion:` field. It is `nil` in every error the
system produces — a ready-made "did you mean" affordance that is never
populated, in a project whose design notes demand suggestions.

Handler crashes surface raw BEAM phrasing (`"bad argument in arithmetic
expression"`) with no rule line number and no offending variable name.

### 5.4 Failures are reported as success

`Anemos.run/2` returns `{:ok, results}` where `results` may contain error
tuples. Verified against `priv/examples/ddns.rule`:

```text
$ mix anemos.run priv/examples/ddns.rule --event CONDITION_networkchanged
Dispatched CONDITION_networkchanged -- 4 operation(s):

  emit %{args: [...], module: "SECRET", type: :command, verb: "unlock"} as katachora.ddns.key
  {:error, %Comn.Errors.ErrorStruct{reason: "validation", field: nil,
    message: "Module INFRA not found in registry", suggestion: nil,
    code: "anemos.runtime/unknown_module", request_id: "tc8emuttg960o",
    trace_id: nil, correlation_id: nil}}
  {:error, %Comn.Errors.ErrorStruct{...same...}}
  emit %{...} to {:channel, "..."} as ddns.update.:{?fqdn}

$ echo $?
0
```

Three problems visible in four lines of output:

- **Exit code 0 despite two hard failures.** The CLI cannot be used in a script
  or CI gate.
- **Raw struct inspection reaches the terminal.** The `other -> inspect(other)`
  fallback (`lib/mix/tasks/anemos.run.ex:49-50`) has no error clause, so
  internal fields including `request_id`, `trace_id`, and `correlation_id` are
  dumped at the user.
- **Errors are counted as "operations."** "4 operation(s)" includes two
  failures.

### 5.5 No recovery path

There is no `when ERROR { ... }` construct (listed as unimplemented in
`TODO.md`), no retry, no fallback. A failed `[MODULE::verb]` inside a rule body
does not stop the rule — execution continues with the failure recorded in the
result list, which is why the ddns example still emits its final operation
using values it never successfully computed.

### 5.6 Duplicate declarations silently coexist

```text
rule r { when EV { log "one" } }
rule r { when EV { log "two" } }
```

Verified result: `{:ok, [%{type: :log, value: "two"}, %{type: :log, value: "one"}]}`

Both rules are kept and both fire. No warning. Since `Anemos.Runtime.load/2`
accumulates declarations across calls, loading the same policy file twice
doubles every rule in it — a realistic operational hazard with no diagnostic.

Note also that the results list order (`"two"`, `"one"`) is the reverse of the
Logger output order (`"one"`, then `"two"`), so the printed sequence and the
returned sequence disagree.

---

## 6. Configuration

### CLI

Two inputs total: a positional file path and `--event`. Argument parsing is
hand-rolled (`lib/mix/tasks/anemos.run.ex:58-65`) via `chunk_every(2, 1,
:discard)` rather than `OptionParser`, so unknown flags are silently ignored
rather than rejected.

Verified behaviours:

```text
$ mix anemos.run priv/examples/garage-lights.rule
** (Mix) --event flag is required                    # acceptable

$ mix anemos.run
Usage: mix anemos.run <file.rule> --event EVENT_NAME  # good

$ mix anemos.run nope.rule --event X
** (File.Error) could not read file "nope.rule": no such file or directory
    (elixir 1.19.5) lib/file.ex:435: File.read!/1
    (anemos 0.1.0) lib/mix/tasks/anemos.run.ex:21: Mix.Tasks.Anemos.Run.run/1
    (mix 1.19.5) lib/mix/task.ex:499: anonymous fn/3 in Mix.Task.run_task/5
    ...
```

A mistyped filename — the most likely CLI mistake — produces a five-frame
Elixir stacktrace. `File.read!` at line 21 has no guard.

There is no `--help`. `mix help anemos.run` renders the moduledoc, which is a
Mix convention a policy author may not know.

### Runtime API

Configuration is entirely programmatic and reads well:

| Call | Configures |
|---|---|
| `Anemos.Runtime.register/2,3` | Module backends for `MODULE::verb` |
| `Anemos.Runtime.load/2` | Policies (accumulative) |
| `Anemos.Runtime.connect/2` | Channel connector for emits |
| `Anemos.Runtime.put_context/3` | Data for `?` resolution |
| `Anemos.Runtime.condition_state/2` | Read condition state |

No config files, no environment variables, no startup configuration — a
deliberate and well-executed design ("blank interpreter, everything loads
dynamically"). `config/config.exs`, `dev.exs`, and `test.exs` exist but carry no
Anemos settings.

There is no way to **unload** a policy or **unregister** a module. Loading is
one-way; correcting a mistake requires restarting the runtime and losing all
state (§4).

---

## 7. Internationalization

**None.** No Gettext dependency, no `priv/gettext`, no locale handling, no
message catalogues. Every user-visible string is hardcoded English, embedded
directly in interpolation sites across `lib/anemos/lexer.ex`,
`lib/anemos/parser.ex`, `lib/anemos/compiler.ex`,
`lib/anemos/runtime/errors.ex`, and `lib/mix/tasks/anemos.run.ex`.

For a developer-facing DSL this is a defensible choice, and I would not
recommend adding Gettext. But it has a real consequence worth naming: because
error strings are built inline with `#{}` interpolation at ~60 sites in the
parser alone, there is **no central place to improve message quality**.
Fixing §5.1 means editing every one of those sites individually. A small
`Anemos.Diagnostics` module that formats `{code, line, token, source_line,
suggestion}` into a message would fix i18n-readiness and message quality with
the same change.

The language's own keywords are English-only (`rule`, `when`, `unless`,
`until`, `for`, `while`), which is normal and not worth changing.

---

## 8. Real-time updates

There is no client to keep current, but the runtime has three live mechanisms:

- **Event dispatch** — synchronous `GenServer.call` through
  `Anemos.Runtime.Dispatcher`. Callers push events in; nothing is pushed out to
  a UI.
- **Scheduler** — `Anemos.Runtime.Scheduler` (222 lines) holds timers for `at`
  blocks and dispatches synthetic `AT_*` events on intervals and recurrences.
- **Dwell timers** — `when EV for 10min` runs a `:listening`/`:armed` state
  machine in dispatcher state (`lib/anemos/runtime/dispatcher.ex:297-319`).
- **Channel connectors** — emits targeting a channel publish through a
  pluggable `Anemos.Channel` behaviour (`Anemos.Channel.ComnBus`, or a custom
  NATS/AMQP implementation). This is the only outbound push path.

The default connector is `Anemos.Channel.Logger`, chosen specifically so emits
are "never silent." That is a good instinct — it is unfortunate the same
instinct was not applied to unbound variables.

**No hot reload.** `TODO.md` lists file watching as unimplemented. Editing a
`.rule` file has no effect until the host calls `load/2` again — which, per §5.6,
duplicates rather than replaces.

---

## 9. Accessibility — read as discoverability and learnability

No ARIA, no keyboard navigation, no screen readers. The equivalent question is
whether a newcomer can find and understand the system.

### What works

- **README.md** (515 lines) is genuinely good: quick example, richer example,
  integration guide, and a construct-by-construct language reference covering
  rules, conditions, capabilities, context, guards, variables, loops, flow
  control, scheduled triggers, modules, emit, triple patterns, expressions, the
  event protocol, and channel connectors. Nearly every section has runnable code.
- **`notebooks/playground.livemd`** (488 lines) — the best learning path.
- **`mix docs`** produces full ExDoc output; `doc/` is committed with HTML,
  markdown, epub, and `llms.txt`.
- **432 tests, 20 doctests, 0 failures** — verified. Test naming maps cleanly
  to language features (`guard_test`, `dwell_timer_test`, `pipeline_test`).
- **`docs/design-notes/`** has its own README index with a description table.

### What does not

- **Nobody outside this machine can build the project.** `mix.exs:39` declares
  `{:comn, path: "../comn"}` — an unpublished sibling repository, absent from
  `mix.lock`. There is no installation section in the README, no note that a
  sibling checkout is required, and no explanation of what `comn` is. The
  Livebook playground's `Mix.install([{:anemos, path: ...}])` inherits the same
  blocker. This is the single largest barrier to a new user.
- **The README links to nothing.** Verified: zero references to `docs/`,
  `design-notes`, `ISSUES.md`, or `TODO.md`. Eight design documents and a
  three-issue tracker are undiscoverable from the entry point.
- **`TODO.md` is substantially false.** It lists as "❌ Not implemented":
  loops, flow control, guards, pipelines, `nextrule`, bitwise operators. All are
  implemented, documented in the README, and covered by passing tests
  (`loop_test.exs`, `flow_control_test.exs`, `guard_test.exs`,
  `pipeline_test.exs`, `pipe_test.exs`). It also claims "✅ All three example
  files parse and run" — see §10.1. A newcomer reading `TODO.md` will
  substantially underestimate the system.
- **A duplicate, differently-stale status file sits in the repo root**:
  `● Here's where we stand against the spec.md` — untracked, with a literal
  bullet glyph in the filename, evidently a pasted terminal transcript. It
  contradicts `TODO.md` (calls loops and guards unimplemented in a *different*
  ordering, and claims rule metadata is done where `TODO.md` calls it partial).
  Two contradicting status documents, neither matching the code.
- **ExDoc publishes dead modules as live API.** Already filed in `ISSUES.md`:
  `Anemos.Runtime.RuleSupervisor` is never started and never referenced, yet
  ships as `doc/Anemos.Runtime.RuleSupervisor.html` indistinguishable from
  working modules. Same for `Anemos.Runtime.DataModelRegistry`.
- **`erl_crash.dump`** (5.9 MB) is committed at the repo root.
- License mismatch: README says "AGPL-3.0", `mix.exs` says "AGPL-3.0-or-later".

---

## 10. Known UX problems, ranked

### 10.1 Two of the three shipped examples do not work

`priv/examples/` is the first thing a user runs. Verified:

| Example | Event | Result |
|---|---|---|
| `garage-lights.rule` | `SENSOR_MOTION_DETECTED` | Works |
| `normalize-pdfs.rule` | `FILE_CREATED` | `No rules matched event FILE_CREATED.` |
| `ddns.rule` | `CONDITION_networkchanged` | 2 of 4 operations fail |

**`normalize-pdfs.rule`** fails twice over. First, its outer guard is
`if [FILE::extension] eq "pdf"` — but the stub `FILE` module returns an echo map
`%{module: "FILE", verb: "extension", args: []}`
(`lib/anemos/runtime/modules/file.ex:14`), which never equals `"pdf"`. Second,
even if it did, the inner `$title`/`$meta_title` sigil bug (§4) makes the body
dead. The file is inert, and `TODO.md` claims it "runs".

**`ddns.rule`** references an `INFRA` module that is not among the two
registered defaults (`DEVICE`, `FILE` — `lib/anemos.ex:14-17`), so both
`[INFRA::get_ip ...]` calls fail. It also demonstrates the interpolation gap:
`as ddns.update.:{?fqdn}` renders literally as `ddns.update.:{?fqdn}` in the
output — the `:{...}` interpolation form appears in the README, both examples,
and the parser, but produces no substitution at runtime and no error.

### 10.2 "No rules matched" is factually wrong

`lib/mix/tasks/anemos.run.ex:27-28` maps `{:ok, []}` to
`"No rules matched event #{event}."` But `[]` means *zero operations produced*,
not *zero rules matched*. For `normalize-pdfs.rule` the rule **did** match, the
handler **did** run, and it produced nothing because a condition was false. The
user is told the opposite of what happened, and is sent looking at the event
name — the one thing that was correct.

These are three genuinely distinct states collapsed into one message: no rule
subscribed to the event; a rule ran but every branch was false; a rule ran and
all its operations failed.

### 10.3 Silent `nil` for every unbound variable

Covered in §4. This is the defect most likely to cost a user hours, because it
produces no signal at all — the language's failure mode for a typo is a
successful run with wrong output.

### 10.4 Error messages speak parser-internal vocabulary

Covered in §5.1. `lbrace`, `rbrace`, `lbracket`, `keyword`, `operator` are
implementation identifiers, not user language.

### 10.5 Unbalanced braces produce a message with no position

`Unexpected end of input, expected statement`. No line, no column, no hint about
which block was left open. This is the single most common syntax mistake in a
brace-delimited language.

### 10.6 The CLI cannot be scripted

Exit code 0 on failure (§5.4). No `--check` or parse-only mode. No `--context`
flag, which means every context-scoped rule in the examples is untestable from
the CLI and the context feature effectively cannot be demonstrated.

### 10.7 Two ways to write a context block, inconsistently used

Both forms parse:

```text
context "garage.motion.sensor" { when EV { ... } }   ; quoted, braced, nests the trigger
context infra.networking                             ; bare dotted path, no braces
when EV { ... }
```

`garage-lights.rule` and `normalize-pdfs.rule` use the first; `ddns.rule` and
every README snippet use the second. Nothing explains when to use which, or
whether the nesting difference is semantically meaningful. The README's own
"Rules" template uses the braced form while its "Richer Example" uses the bare
form — in the same document.

### 10.8 Whole-string prefix matching on context paths

`String.starts_with?` with no segment boundary (§3.1). `context "garage"`
captures `"garagedoor.sensor"`. For a construct whose documented purpose is
isolation, this is a correctness problem wearing a usability disguise.

### 10.9 Empty and near-empty files parse successfully

`""` and `"\n\n\n"` both return `{:ok, %Program{declarations: []}}`. Combined
with 10.2, an empty file and a working file are indistinguishable from the CLI
— both print "No rules matched."

### 10.10 `suggestion:` exists and is never used

Every `Comn.Errors.ErrorStruct` the system produces has `suggestion: nil`. The
unknown-module and unknown-verb errors have the full registry in hand at the
moment of failure and could trivially offer the closest match. In a project
whose design notes make "error messages should suggest corrections" an explicit
principle, an unused suggestion field is the clearest single gap between
intent and implementation.

---

## Summary judgement

**The language design is good.** The declaration grammar is regular and
learnable, the sigil model is coherent on paper, the runtime API ("blank
interpreter, load everything dynamically") is well-judged, and the
`Anemos.Module` extension point is close to ideal. The README and the Livebook
playground are better than most v0.1.0 documentation, and 432 passing tests back
real feature coverage.

**The diagnostics are the weak half, and they are weak in a specific,
correctable way.** The system is built to keep going: unbound variables become
`nil`, failed commands are recorded and execution continues, errors ride home
inside `{:ok, ...}`, and the process exits 0. That is a reasonable posture for a
long-running policy engine that must not die on one bad rule. It is the wrong
posture for the authoring loop, and Anemos currently applies it to both. The
result is a language that will not tell you when you are wrong.

The three highest-leverage fixes, in order:

1. **Make unbound variables loud.** Distinguish "not bound" from "bound to nil"
   in `resolve_expr` (`lib/anemos/compiler.ex:739-750`) and surface the former
   as a diagnostic. This alone would have caught the bug in the shipped
   `normalize-pdfs.rule`.
2. **Add a semantic validation pass** between compile and load: unknown modules,
   unknown verbs, unknown capabilities, unknown `nextrule` targets, sigil/keyword
   mismatches, duplicate names. All are checkable with information already in
   hand, and all are currently deferred to runtime or not checked at all.
3. **Centralize diagnostic formatting.** Thread the lexer's already-computed
   column through the token metadata, add a source-line excerpt with a caret,
   translate token atoms to user-facing names, and populate `suggestion:`. Doing
   this in one `Anemos.Diagnostics` module fixes ~60 scattered interpolation
   sites and makes the project's own principle 6 achievable.

And before any of that: fix the two broken examples and the false `TODO.md`,
because those are what a newcomer meets first.

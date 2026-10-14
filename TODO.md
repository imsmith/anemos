# Anemos — implementation status

**Last verified:** 2026-08-07, against branch `hardening/supervision-and-trust-boundary`.
Compound triggers, the binding check and "Known gaps" re-verified 2026-10-04.

Every claim below was checked by running the code, not by reading it. Where a construct
parses but does nothing at runtime, it is listed as **inert** rather than implemented —
that distinction is what made the previous version of this file misleading in the direction
that matters least helpfully, by understating what works while overstating what runs.

Defects in implemented features are tracked in `ISSUES.md`, not here. This file answers
"does the feature exist", `ISSUES.md` answers "does it work correctly".

## Working end to end

Verified by the test suite (48 doctests, 790 tests, 0 failures) and by direct execution.

- Lexical structure — comments, strings, numbers, durations, sigils, identifiers, atoms
- Boolean literals — `true` / `false` as real booleans
- `rule`, `condition`, `capability`, `data`, `query` declarations
- Format `data` blocks — `data d { <format> { ... } }`, with `transclude ... as name` — built
  by the `Anemos.DataModel` handler the host registered for the format
- `query` blocks — called from a rule by name, `?query-name`; `expect`ed bindings come from
  the caller's scope; run by the handler registered for the engine. Not callable from a
  condition or capability body
- `signed_by` at source level — provenance on a file that declares no rule
- `when` blocks, including compound events — `AND` is a compound state over each operand's
  last report; the block fires at every report at which that state is true
- `when EV for <duration>` — dwell-timer state machine
- `at` blocks — time literals, intervals, recurring schedules, natural-language dates
- `if` / `elseif` / `else`
- Guards — `unless` (stateless), `until` (stateful, permanent on rules)
- `let`, `set`, `log`, `emit` (with type, destination and label)
- `demand` with PAM control flags — `--required`, `--optional`, `--sufficient`, `--requisite`
- `[MODULE::verb]` commands in **statement and expression** position — an expression-position
  call is dispatched at evaluation and its return value *is* the value of the expression
- Loops — `while`, `for`, `each`, `every`, `foreach`
- Flow control — `return`, `done`, `nextevent`, `nextrule`
- `nextrule` and `nextevent` `<target> with { key: value }` — argument passing
- Pipelines — `|>` with `filter`, `map`, `reduce`
- Triple patterns — assertion and query
- Comparison, logical, membership and bitwise operators, over a 14-level precedence table
- `AND` compounds over non-boolean operands, `OR` alternates — see the `Anemos.Compiler`
  moduledoc for the algebra
- `in`, `contains`, `starts_with`, `ends_with`, `matches_glob`, `memberof`
- Context filtering — segment-aware and fail-closed
- Variable sigil differentiation — `?` external, `@` ephemeral, `$` persistent
- All three shipped examples in `priv/examples/` — `garage-lights`, `ddns`, `normalize-pdfs`

### Runtime

- Two-tier supervision: `StoreSupervisor` for infrastructure stores, `RuleSupervisor` as
  the per-rule tier
- `PolicyStore` — loaded policy survives a dispatcher crash
- Hot reload — `load/3` with `policy: id` deploys a policy over itself; `unload/2`,
  `policies/1`; `Anemos.Runtime.Watcher` keeps a directory of `.rule` files deployed
- Introspection from the host — `describe/1` (everything loaded, with its state),
  `explain/3` (what an event would do), `trace/2` (what the last 200 dispatches did)
- Introspection statements — `show`, `list`, `graph`, `trace`, `explain`, `exists`,
  `infer`, `assert`, after Comn's look / recon / choices; `exists` also as a value
- `StateTable` — `set` bindings, dwell timers, condition values, module registrations,
  context data and the policy record survive the restart of any process in the runtime
- Bounded event recursion, ceiling 10,000
- `LoadAuthority` — pluggable authorization on `load/3`, with an unwaivable byte ceiling
- `arg_schema/1` — optional per-verb argument validation enforced before dispatch
- `PathGuard` — segment-aware path confinement, fails closed on an unconfigured root
- `Anemos.Secret` — redacting wrapper surviving `inspect`, interpolation and `Logger`
- Write-once module registration
- CLI: `--event`, `--context`, `--context-data`, `--stub-modules`, `--help`, real exit codes
- Detached Ed25519 signature verification on `load/3`, with `unsigned_policy` of
  `:permit` / `:warn` / `:strict`
- `Parser.parse/1` is total over binaries — it answers a tuple for any input, never raises,
  and terminates. Covered by a truncation sweep and a mutation fuzzer, not by inspection

## Partially implemented

| Feature | State |
| --- | --- |
| `until` on conditions | Compiles as "false while guard holds"; cannot latch permanently (A-48) |
| Message envelope | `source`, `timestamp`, `label`, `channel` populated; `signature` never set |
| `data` blocks — dynamic | `subscribe` works; `periodic` is parsed and unimplemented |

## Parses but inert

Accepted by the parser, produces nothing at runtime. Listed separately because "it parses"
has repeatedly been mistaken for "it works".

- **`when ERROR { ... }`** — parses only because `ERROR` is an ordinary event name. Nothing
  in the runtime emits such an event, so the block never fires. This is not error handling
- **`:{...}` interpolation in labels** — e.g. `as ddns.update.:{?fqdn}` renders literally,
  with no substitution and no error. Appears in the README and both examples

## Not implemented

No lexer or parser support. Verified by attempting to parse each one.

- `it` / `on` / `as` blocks — modal refs, invocation refs, group specs. `AST.It`, `AST.On`
  and `AST.Flow` exist as structs the parser never constructs
- `flow` declarations
- Regex and string sigils — `~r`, `~s`
- Size literals — `KB`, `MB`, `GB`, `TB`
- `systemd()` destination
- Signing (producing signatures). Anemos verifies; something else signs — deliberate, see
  `ISSUES.md` A-05

## Known gaps that are not features

Recorded so they are not mistaken for missing syntax:

- References are validated at runtime, by decision: an unknown module, capability,
  `nextrule` target, `memberof` dataset or query engine is a structured error where it is
  reached, not at load. An unknown verb is the host module's to refuse (A-31, A-44)
- A `@name` / `$name` that nothing binds is a compile error, but `$name` read before its
  first `set`, a `?name` the environment did not supply, and a bare word where a variable
  was meant still resolve silently (A-25)
- No CI — there is no git remote. Credo, Dialyzer and `mix check` exist (A-27)
- Runtime state survives the restart of any process in the runtime, not the node (A-79)

## Conventions

Anything added here should be verified by execution before it is claimed. The previous
version of this file listed loops, flow control, guards and pipelines as unimplemented for
months after they shipped, tested, and were documented in the README — which cost a reader
more than an empty file would have.

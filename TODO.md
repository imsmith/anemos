# Anemos — implementation status

**Last verified:** 2026-08-07, against branch `hardening/supervision-and-trust-boundary`.

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
- `signed_by` at source level — provenance on a file that declares no rule
- `when` blocks, including compound events with `OR`
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
| Compound `AND` events | Parses, but compiles identically to `OR` — fires on either event (A-47) |
| Keyword arguments — `type:ipv4` | Parses; flattened to positional, structure discarded (A-57) |
| `until` on conditions | Compiles as "false while guard holds"; cannot latch permanently (A-48) |
| Message envelope | `source`, `timestamp`, `label`, `channel` populated; `signature` never set |
| `data` blocks — dynamic | `subscribe` works; `periodic` is parsed and unimplemented |

## Parses but inert

Accepted by the parser, produces nothing at runtime. Listed separately because "it parses"
has repeatedly been mistaken for "it works".

- **`data { <format> { ... } }` format blocks** — compile to `dataset: nil` and are dropped
  by the dispatcher without a log line (A-34)
- **`query` blocks** — compile to a handler that echoes its own inputs; nothing ever reads
  `query_blocks` (A-35)
- **`when ERROR { ... }`** — parses only because `ERROR` is an ordinary event name. Nothing
  in the runtime emits such an event, so the block never fires. This is not error handling
- **`:{...}` interpolation in labels** — e.g. `as ddns.update.:{?fqdn}` renders literally,
  with no substitution and no error. Appears in the README and both examples
- **`Anemos.DataModel` behaviour** — declared; `parse/1`, `eval/2`, `transduce/3` have no
  callers

## Not implemented

No lexer or parser support. Verified by attempting to parse each one.

- Introspection verbs — `show`, `list`, `graph`, `trace`, `explain`, `exists`, `infer`
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

- No semantic validation pass between compile and load. Unknown modules, verbs,
  capabilities and `nextrule` targets are all deferred to runtime (A-31, A-44)
- Unbound variables resolve silently to `nil`; a typo produces a successful run with wrong
  output (A-25)
- No CI, no linting, no Dialyzer (A-27)
- `{:comn, path: "../comn"}` is an unpublished sibling checkout, so the repository does not
  build standalone (A-28)
- Persistent `set` bindings, armed dwell timers and module registrations do not survive the
  relevant restart (A-40, A-41, A-43)

## Conventions

Anything added here should be verified by execution before it is claimed. The previous
version of this file listed loops, flow control, guards and pipelines as unimplemented for
months after they shipped, tested, and were documented in the README — which cost a reader
more than an empty file would have.

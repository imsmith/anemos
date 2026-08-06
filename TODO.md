# Anemos — implementation status

**Last verified:** 2026-08-06, against branch `hardening/supervision-and-trust-boundary`.

Every claim below was checked by running the code, not by reading it. Where a construct
parses but does nothing at runtime, it is listed as **inert** rather than implemented —
that distinction is what made the previous version of this file misleading in the direction
that matters least helpfully, by understating what works while overstating what runs.

Defects in implemented features are tracked in `ISSUES.md`, not here. This file answers
"does the feature exist", `ISSUES.md` answers "does it work correctly".

## Working end to end

Verified by the test suite (36 doctests, 631 tests, 0 failures) and by direct execution.

- Lexical structure — comments, strings, numbers, durations, sigils, identifiers, atoms
- Boolean literals — `true` / `false` as real booleans
- `rule`, `condition`, `capability` declarations
- `when` blocks, including compound events with `OR`
- `when EV for <duration>` — dwell-timer state machine
- `at` blocks — time literals, intervals, recurring schedules, natural-language dates
- `if` / `elseif` / `else`
- Guards — `unless` (stateless), `until` (stateful, permanent on rules)
- `let`, `set`, `log`, `emit` (with type, destination and label)
- `demand` with PAM control flags — `--required`, `--optional`, `--sufficient`, `--requisite`
- `[MODULE::verb]` commands **in statement position**
- Loops — `while`, `for`, `each`, `every`, `foreach`
- Flow control — `return`, `done`, `nextevent`, `nextrule`
- `nextrule <target> with { key: value }` — argument passing
- Pipelines — `|>` with `filter`, `map`, `reduce`
- Triple patterns — assertion and query
- Comparison, logical, membership and bitwise operators, over a 14-level precedence table
- `in`, `contains`, `starts_with`, `ends_with`, `matches_glob`, `memberof`
- Context filtering — segment-aware and fail-closed
- Variable sigil differentiation — `?` external, `@` ephemeral, `$` persistent

### Runtime

- Two-tier supervision: `StoreSupervisor` for infrastructure stores, `RuleSupervisor` as
  the per-rule tier
- `PolicyStore` — loaded policy survives a dispatcher crash
- Bounded event recursion, ceiling 10,000
- `LoadAuthority` — pluggable authorization on `load/3`, with an unwaivable byte ceiling
- `arg_schema/1` — optional per-verb argument validation enforced before dispatch
- `PathGuard` — segment-aware path confinement, fails closed on an unconfigured root
- `Anemos.Secret` — redacting wrapper surviving `inspect`, interpolation and `Logger`
- Write-once module registration
- CLI: `--event`, `--context`, `--context-data`, `--stub-modules`, `--help`, real exit codes

## Partially implemented

| Feature | State |
| --- | --- |
| Compound `AND` events | Parses, but compiles identically to `OR` — fires on either event (A-47) |
| `[MODULE::verb]` in expression position | Parses; never dispatched. Returns a descriptor map, not a value (A-56) |
| Keyword arguments — `type:ipv4` | Parses; flattened to positional, structure discarded (A-57) |
| `signed_by` | Parsed; verification in progress |
| `until` on conditions | Compiles as "false while guard holds"; cannot latch permanently (A-48) |
| Message envelope | `source`, `timestamp`, `label`, `channel` populated; `signature` never set |
| `data` blocks — dynamic | `subscribe` works; `periodic` is parsed and unimplemented |
| Shipped examples | `garage-lights` and `ddns` run; `normalize-pdfs` blocked on A-56 |

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
- **`AST.NextEvent.args`** — declared with no producer and no consumer (A-55)

## Not implemented

No lexer or parser support. Verified by attempting to parse each one.

- Introspection verbs — `show`, `list`, `graph`, `trace`, `explain`, `exists`, `infer`
- `it` / `on` / `as` blocks — modal refs, invocation refs, group specs. `AST.It`, `AST.On`
  and `AST.Flow` exist as structs the parser never constructs
- `flow` declarations
- Regex and string sigils — `~r`, `~s`
- Size literals — `KB`, `MB`, `GB`, `TB`
- `systemd()` destination
- Hot reload / file watching
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

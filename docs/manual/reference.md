# Language and API reference

This reference summarizes Anemos 0.1.0 as implemented. Read the chapters for
motivation, worked examples, and behavioral qualifications. Templates below
use angle brackets for placeholders and square-bracketed English descriptions
for optional material; those markers are not literal DSL syntax.

## Source structure

A source contains zero or more declarations. Supported top-level declarations
are `rule`, `condition`, `capability`, `data`, `query`, and `signed_by`.
Statements do not run at source level. Declaration names should be lowercase
identifiers. Use one context boundary per rule/condition.

```text
signed_by :<signer>

rule <name> {
  [version "<version>"]
  [signed_by :<signer>]
  [scope local | global | mesh]
  [context <path>]
  <when/at blocks and inline data/query declarations>
}

condition <name> {
  [context <path>]
  <when/at blocks>
  [if <predicate> {}]
}

capability <name> {
  [context <path>]
  on demand { <statements> }
}
```

`version` and rule `scope` are metadata. They do not enforce package version
selection, distribute rules across a mesh, or replace context access checks.
`signed_by` identifies source signers to the configured load authority; it
does not contain a signature. Metadata belongs before a rule's body statements.

Braced contexts and bare dotted contexts are supported:

```text
context "building.garage" { <trigger blocks> }
context building.garage
```

A quoted context currently expects a braced body. Use the bare dotted form
for a context line without a body.

## Lexical conventions

| Construct | Form |
| --- | --- |
| Comment to end of line | `; comment` or `# comment` |
| String | `"text"`; escapes `\"`, `\\`, `\n`, `\t` |
| Integer / float | `42`, `3.5`; negative through subtraction or host data |
| Boolean | `true`, `false` |
| Symbol | `:name`, `:dotted.name`; runtime string value |
| Identifier | Lowercase initial; letters, digits, `_`, `-`, `.` afterward |
| Module / event name | `DEVICE`, `FILE_CREATED`, `CONDITION_ready` |
| Variable | `?name`, `@name`, `$name`; letters/digits/underscores |
| Command qualification | `MODULE::verb` |
| Block | `{ ... }` |
| Command / triple | `[ ... ]` |

Newlines and spaces do not delimit statements by themselves; keywords and
expression boundaries do. Semicolons start comments. For readability, put
one statement per line and spaces around infix operators. Only lowercase
booleans are literals. There is no `nil` literal, single-quoted string form,
general map literal, or general square-bracket list literal.

Recognized keyword tokens are:

```text
rule when if at on it let set emit demand condition capability flow context
else elseif while for each every foreach do return done nextevent nextrule
log show list graph trace explain exists infer assert unless until as with
by that import export version signed_by scope state effect stream to channel
service self interval then filter map reduce data query source expect
transclude dynamic subscribe periodic memberof global
```

Recognition as a keyword does not mean a construct is implemented. See feature
status below, particularly `flow`, `import`, `export`, `it`, and destinations.

## Bindings and lookup

| Write | Read | Scope/lifetime |
| --- | --- | --- |
| Host payload/context field | `?name` | Current dispatch's `context_data` |
| `let name = expression` | `@name` | Current handler evaluation |
| `set name = expression` | `$name` | Named rule across firings |
| `for name in collection` | `@name` | Current iteration; removed afterward |
| Pipeline `filter ?name` / `map ?name` | `?name` | Current pipeline element |
| Pipeline `reduce acc initial ?name` | `$acc`, `?name` | Reduction accumulator and element |

`?name` resolution: context data, then a visible named query, then a visible
dataset, then `nil`. Local data/query scope is the named rule, and local
definitions shadow global definitions. Query expected-input resolution:
`let`, then `set`, then string-keyed context data. A missing expected input
is an error.

Only boolean `false` and `nil` are falsey. `exists expression` is true for
any non-`nil` value, including false. The compiler catches references to an
`@`/`$` name with no possible binder anywhere in the declaration; it does
not prove execution-path initialization.

## Triggers

```text
when <EVENT> [for <duration>] [unless <expr> | until <expr>] {
  <statements>
}
when (<EVENT> AND <EVENT> ...) { <statements> }
when (<EVENT> OR <EVENT> ...) { <statements> }

at <time-spec> [unless <expr> | until <expr>] { <statements> }
```

Use homogeneous compound event groups. Compound reports start false and are
replaced by incoming reports. `state: false`/`nil` makes a report false;
absent `state` makes it true. A compound rule can fire repeatedly while the
combination remains true; a condition acts only on a false-to-true transition.

Supported time specifications:

| Form | Behavior |
| --- | --- |
| `13:00`, `TIME_1300` | Next occurrence, once |
| `interval(5min)` | Repeating elapsed interval |
| `09:00 every day` | Daily |
| `09:00 every weekday` | Monday–Friday |
| `09:00 every monday` | Weekly, named day |
| `DATE_2099.04.15` | One calendar date |
| `DAY_friday` | Next named day, once |
| `NLD_tomorrow` | Resolved relative date, once |

Compact duration suffixes: `ms`, `s`, `min`, `h`, `d`. Use nonnegative whole
amounts. Zero dwell is immediate; intervals must meet the configured minimum.
NLD expressions: `today`, `tomorrow`, `yesterday`, `next.<weekday>`, `next.week`,
`next.month`, `next.year`, `end.of.month`, `end.of.week`.
See [time semantics and limitations](07-time.md), including local time,
past-date refusal, captured dwell context, and unscoped scheduler events.

## Handler statements

```text
let <name> = <expression>
set <name> = <expression>
log <expression>
[MODULE::verb <arguments>]

if <expression> [unless <guard>] { <statements> }
  elseif <expression> { <statements> }
  else { <statements> }

while <expression> { <statements> }
for <name> in <expression> { <statements> }
each <name> in <expression> { <statements> }
every <name> in <expression> { <statements> }
foreach MODULE::verb { <statements using @item> }

return
done
nextevent <EVENT> [with { key: <expr>, other: <expr> }]
nextrule <rule-name> [with { key: <expr>, other: <expr> }]

demand <capability-name> [--requisite | --required | --optional | --sufficient]
emit [state | effect | stream] [MODULE::verb <arguments>]
  [to channel(<path>)] [as :<label>]

show <subject>
explain <subject>
list <subject>
graph <expression>
trace <expression>
infer <expression>
exists <expression>
assert <expression>

let [:subject -> :predicate -> :object]
```

`else if` is an alternative to `elseif`. Commands accept whitespace-separated
arguments and optional commas/parenthesized argument syntax. For computed
arguments, bind intermediate expressions with `let` for clarity. For example:

```anemos
rule calculated-command {
  when NUMBER {
    let next_value = ?value + 1
    [MATH::double @next_value]
  }
}
```

`return`/`done` stop this handler, not all event listeners. `return value`
does not provide a return value in the current evaluator. `nextevent`
broadcasts by event; `nextrule` selects by named rule. Both preserve context,
overlay `with` data on the original payload, and enforce receiving context.

Inspection subjects may be module/event names, expressions, or catalogue
names `rules`, `conditions`, `modules`, `events`, `policies`, `schedules`.
`assert` requires an expression; use `assert exists DEVICE` to test a module
registration rather than asserting a bare name.

## Expressions and pipelines

```text
<literal or variable>
[MODULE::verb <arguments>]
(<expression>)
(<value> <value> ...)
<unary-operator> <expression>
<expression> <binary-operator> <expression>
<expression> memberof(<dataset-name>, <dataset-name>, ...)

<collection> |> filter ?item (<predicate>)
<collection> |> map ?item (<expression>)
<collection> |> reduce accumulator <initial> ?item (<expression using $accumulator>)
<collection> |> [MODULE::verb <extra-arguments>]
```

The final form prepends the collection as one command argument and returns
the host command's value. Pipeline collection functions wrap a scalar as one
element and treat `nil` as empty. A bare pipeline is an expression, not a
standalone handler statement: bind it or use it as another statement's value.

### Operator precedence

Lowest binding power first. Binary operators associate to the left. Unary
operators bind above binary operators, and grouping parentheses override
precedence.

| Level | Operators |
| --- | --- |
| 0 | `\|>` |
| 1 | `in`, `notin`, `contains`, `starts_with`, `ends_with`, `matches_glob`, `matches_regex`, `memberof` |
| 2 | `OR`, `or`, `\|\|` |
| 3 | `AND`, `and`, `&&` |
| 4 | Bitwise `\|` |
| 5 | Bitwise `^` |
| 6 | Bitwise `&` |
| 7 | `==`, `!=`, `===`, `!==`, `eq`, `ne` |
| 8 | `<`, `<=`, `>`, `>=`, `lt`, `le`, `gt`, `ge` |
| 9 | `<<`, `>>` |
| 10 | `+`, `-` |
| 11 | `*`, `/`, `%` |
| Above binary | Unary `not`, `!`, `~` |

Uppercase `IN` is accepted in expression membership position as well. Other
word comparisons use the lowercase spellings listed. `matches_glob` is in the
precedence table but not implemented at evaluation time.

`AND` compounds non-boolean values, dropping `true` and absorbing the first
falsey operand. `OR`/`||` chooses the first truthy value, or the first operand
when all are falsey. `&&` returns the falsey left value or the right value.
All are eager, including host calls in operands. See [Chapter 3](03-values-and-expressions.md#logical-operators-also-carry-values)
for shape examples and mixed-value rules.

## Data and queries

```text
data <name> {
  <simple values>
}

data <name> {
  [source <resource.path>]
  <format-keyword> { <handler body> }
  [transclude to shape(<shape.path>) with <transducer.path> as <binding>]
}

data <name> {
  dynamic { subscribe <protocol> "<uri>" [periodic <spec>] }
}

query <name> {
  [expect :input, :other_input]
  <engine-keyword> { <handler body> }
  return ?output
}
```

Top-level data/query declarations are global. Inline declarations are local
to the named rule unless written `data global <name>` or `query global <name>`.
Only simple sets work without a host data handler. Format/engine bodies are
token-reconstructed text, not arbitrary raw source. `source` is metadata;
dynamic protocol handlers implement fetching/subscription. `periodic` does
not itself provide polling. Query access through `?name` executes the query;
it does not cache it.

Triple assertions work as facts; query pattern evaluation is partial. See
[Chapter 8](08-data.md#facts-and-triple-patterns) before using patterns as values.

## Command-line reference

```sh
mix anemos.run path/to/policy.rule --event EVENT_NAME [options]
```

| Option | Meaning |
| --- | --- |
| `--event NAME`, `-e NAME` | Required event to dispatch |
| `--context PATH`, `-c PATH` | Caller path for listener boundaries |
| `--context-data KEY=VALUE` | Repeatable string-valued payload fields |
| `--stub-modules` | Opt into bundled demonstration module doubles |
| `--help`, `-h` | Usage |

The bundled example doubles cover `EVENT`, example `FILE`, `INFRA`, `PDF`,
`SECRET`, and `STRING`. They do no external work. The one-shot path normally
registers only development `DEVICE` and `FILE` stubs. A persistent runtime
starts with `POLICY` and host registrations, not the one-shot stub defaults.

The CLI dispatches once and exits. Exit `1` covers usage/read/load/parse/
compile/operation errors. Exit `0` means no reported operation errors, not
that a required action occurred. Context-data parsing splits only the first
`=`; a key without `=` receives an empty string.

## Host API quick reference

`rt` below is the host-controlled runtime atom, usually `:anemos`.

| Call | Result / purpose |
| --- | --- |
| `Anemos.run(source, event: name, ...)` | `{:ok, results}` or `{:error, reason}`; one-shot |
| `Anemos.run_report(source, event: name, ...)` | Detailed one-shot report or load error |
| `Runtime.start_link(name: rt, ...)` | Start supervised runtime |
| `Runtime.register(rt, module)` | Register a macro-defined module by its embedded name |
| `Runtime.register(rt, "NAME", module)` | Register explicit command name |
| `Runtime.register_data_model(rt, handler)` | Register format/query handler by `keyword/0` |
| `Runtime.put_context(rt, "key", value)` | Write context store; currently not merged into dispatch lookup |
| `Runtime.connect(rt, connector)` | Replace current channel connector |
| `Runtime.load(rt, source, policy: id, ...)` | `:ok`, `{:partial, failures}`, or `{:error, reason}` |
| `Runtime.unload(rt, id)` | Remove a named policy |
| `Runtime.policies(rt)` | Loaded policy ownership information |
| `Runtime.dispatch(rt, name, context, opts)` | `{:ok, results}`; inspect individual errors |
| `Runtime.dispatch(rt, event_struct_or_map)` | Dispatch through `Anemos.Event` |
| `Runtime.condition_state(rt, "name")` | `true`, `false`, or absent `nil` |
| `Runtime.describe(rt)` | Runtime inventory, state, and schedules |
| `Runtime.explain(rt, name, context)` | Reachability without guard/body evaluation |
| `Runtime.trace(rt, limit)` | Newest-first recent dispatch history |
| `Runtime.Watcher.status(watcher)` | Last deployment status by file |
| `Runtime.Watcher.scan(watcher)` | Force one scan |

`Runtime` abbreviates `Anemos.Runtime`. All calls are Elixir, not DSL syntax.
Public API module documentation gives specs and additional options.

One-shot options: `event:`, `context:`, `context_path:`, `context_data:`,
`modules:`, `authorization:`. Runtime startup options: `name:`, `modules:`,
`watch:`, `keyring:`, `unsigned_policy:`. Load options: `policy:`,
`authorization:`. Dispatch accepts `timeout:` in its fourth argument.

String dispatch context uses `%{context_path: path, context_data: payload}`.
Map-protocol events use `%{name: name, context: path, payload: payload}`.
Use string keys within payloads.

### Extension contracts

| Interface | Required operations | Optional / notes |
| --- | --- | --- |
| `Anemos.Runtime.Module` | `handle_verb/3` | `arg_schema/1`, `describe/1`; macro `use Anemos.Module` |
| `Anemos.Event` | `name/1`, `context/1`, `payload/1` | Protocol for application event values |
| `Anemos.Channel` | `publish/2` | Receives envelope; host owns delivery guarantees |
| `Anemos.DataModel` | `keyword/0`, `parse/1`, `eval/2`, `transduce/3` | Return `{:error, :not_supported}` for unsupported transformations |
| `Anemos.Subscribable` | `subscribe/3`, `unsubscribe/1`, `periodic?/0`, `interval/1` | Adapter owns actual feed/polling |
| `Anemos.Runtime.LoadAuthority` | `authorize/1` | Receives `LoadRequest`; default permissive |

## Feature status

These distinctions are part of the documentation contract, not implied
promises that unfinished syntax will acquire a particular future meaning.

| Feature | Current behavior | Practical guidance |
| --- | --- | --- |
| Rules, context boundaries | Implemented; one extracted context per declaration | Use one explicit scope |
| `let`, `set`, expressions, branches | Implemented | Initialize persistent state inside a handler |
| `put_context/3` | Stores values separately; ordinary dispatch does not resolve them | Merge defaults into event `context_data` in the host |
| Command statements / values | Implemented with different execution timing | Read Chapter 2 before depending on side-effect order |
| Explicit collection iteration / pipelines | Implemented | Supply lists; use explicit loop sources |
| Bare `each item` / `every item` | Parses but has no iterable and does no work | Use `each item in ?items` or `for` |
| Pipeline `emit` | Descriptors discarded; no reliable per-item dispatch | Use a `for` with command statements |
| `until` | Latch can be lost; ignored on `if`; fresh guard on conditions | Use explicit persistent state with `unless` |
| Conditions | Trigger/predicate state and rising-edge actions implemented | One transition body per condition; no condition dwell |
| Capability demand | Each demand is its own stack; later statements continue | Do not use as an authorization gate |
| Capability body operations | Returned as results, not recursively executed | Expression host calls execute; do not infer queued execution |
| `return value` | Parses; value ignored | Use bare return or explicit handoff |
| `nextevent` | Broadcasts to all eligible event subscribers | Choose event names accordingly |
| `nextrule` | Calls every compiled handler with target name | Prefer one-action target rules |
| `at` in scoped rules | Timer events have no context, so boundary denies | Schedule scoped events in host |
| `at` persistent bindings | Generated time handlers have separate names/state | Use host-scheduled ordinary events to share `when` state |
| Local calendar schedules | Implemented with local naive time | Externalize zone/DST/durable scheduling requirements |
| Simple datasets / `memberof` | Exact membership implemented | CIDRs are strings, not subnet matchers |
| Format data / queries / transclusion | Host handlers required | Register before loading; inspect failures |
| Embedded engine text | Reconstructed tokens, not original bytes | Keep handler grammar compatible |
| Dynamic feeds | Subscription/update/cancellation implemented | Host supplies adapters and polling |
| Triple assertions / `graph` | Implemented | Shared runtime fact store |
| Triple queries in expressions | Descriptor values, not bound rows | Use host matching/query services |
| `matches_glob` | Parsed; evaluator falls back to false | Use `matches_regex` or a host matcher |
| `++`, `~&`, `~\|` | Tokenized, not working binary expression operators | Use implemented operators or host verbs |
| Unary minus | Not parsed | Use subtraction, such as `0 - 5` |
| Interpolated symbols / labels | Parsed text is not dynamically resolved | Use fixed labels and explicit payloads |
| `to service(...)`, `to self` | Parsed destination forms lack channel delivery handling | Use `to channel(...)` |
| General `emit value` | Not implemented; command form required | Emit a host command's result |
| Rule `version`, `scope` | Descriptive metadata | Do not infer version enforcement/distribution |
| `signed_by` | Enforced only through an appropriate load authority | Configure signed verification explicitly |
| `flow`, `import`, `export`, modal `it` | Reserved/design vocabulary, no working feature | Compose implemented rules and host services |

[Glossary and index](glossary.md) · [Contents](README.md)

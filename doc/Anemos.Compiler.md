# `Anemos.Compiler`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/compiler.ex#L96)

Walks the AST produced by `Anemos.Parser` and produces `%Anemos.CompiledRule{}`,
`%Anemos.CompiledCondition{}`, and `%Anemos.CompiledCapability{}` structs with
executable closures. No code generation, no Module.create.

## Boolean comparison (A-46)

`true` and `false` are boolean literals. `?flag == true` compares against the
boolean `true`, not the string `"true"`.

**Comparison does not coerce.** `?flag == "true"` still means *the string*
`"true"` and keeps working for a host whose payload is string-valued; it does
not match a payload carrying the boolean. The two are different values and
`==` says so.

Coercion was rejected because the operand types are not knowable at compile
time. Context data arrives from arbitrary host payloads, so a rule making
`"true" == true` answer `true` would also have to make `"1"`, `"yes"` and
`"TRUE"` answer something, and the choice would be invisible to the policy
author. Making the mismatch a *compile* error was rejected for the same
reason: the parser sees a literal on one side and an unresolved `?var` on the
other, and cannot know what the host will send.

What is not acceptable is the silent wrong answer that A-46 reported. So a
comparison in which one side is a boolean and the other is the string
`"true"` or `"false"` logs a warning at the moment it is evaluated, naming
both operands, and then answers as the values dictate — `==` false, `!=`
true. The author gets told the shapes disagree rather than reading a guard
that never fires.

## `AND` compounds; it does not merge (A-73)

`AND` is two operators sharing a spelling, and which one you get is decided
by the operands.

Over booleans it is logical conjunction and means what it has always meant:
`if ?x eq 1 AND ?y eq 2` fires only when both comparisons hold.

Over anything else it **compounds** — `let update = (A) AND (B)` means "let
`update` have the value `A` *and* the value `B`", not "let `update` have the
value `A`-combined-with-`B`". The binding is a collection of both operands:

    let update = (:h IN A "1.1.1.1") AND (:h IN AAAA "::1")

    @update == [["h", "IN", "A",    "1.1.1.1"],
                ["h", "IN", "AAAA", "::1"]]

The defect this replaced was `l && r`, which in Elixir *answers `r`*
whenever `l` is truthy. Over non-boolean operands the left one was evaluated
and silently thrown away, so `priv/examples/ddns.rule` read as "update both
records" and updated one.

### Why the spine is flattened before evaluation

A parenthesised triple pattern evaluates to a **list** —
`["h", "IN", "A", "1.2.3.4"]` — so a compound of triples is a list of lists,
and a *runtime* rule such as "if the left operand is already a list, append
to it" cannot tell a triple from an already-compounded pair. It would turn
`["h", "IN", "A", "x"] AND C` into `["h", "IN", "A", "x", C]`.

`AND` is left-associative, so `(A) AND (B) AND (C)` parses as
`((A AND B) AND C)` and naive nesting yields `[[A, B], C]` rather than
`[A, B, C]`.

Both problems are the same problem — runtime values are ambiguous where the
AST spine is not. So `flatten_and_spine/1` collects the whole chain of
`%AST.BinaryOp{op: :and}` nodes into one operand list *before* any of them
is evaluated, and the decision is taken once over the whole list. There is
no runtime wrapper struct and no marker tuple: a compound is an ordinary
list by the time it reaches a binding, because it flows on into calls like
`[INFRA::ddns_update ...]` as an argument and host code must not have to
understand an Anemos-internal type.

### Mixed operands

Not settled by the A-73 decision; chosen here, and stated so it can be
overruled cheaply. `true` is the **identity of conjunction**, and a falsey
operand is **absorbing**:

  * Any operand that is `false` or `nil` answers that value for the whole
    `AND`, and nothing is compounded. This keeps every truthiness guard
    working — `if ?missing AND ?present` stays false rather than becoming
    the truthy list `[nil, "here"]`.
  * `true` operands are dropped from the compound, since "the value `true`
    and the value `X`" carries nothing `X` does not. `true AND (A)` is `A`;
    `true AND true` is `true`.

Both alternatives were worse. Compounding `true` in would put a boolean in
the middle of a DNS payload; making the mix a compile error is not available
for the same reason it was not available to A-46 — operand types are not
knowable at compile time, since a `?var` is whatever the host sent.

### `&&` is unchanged

`&&` remains purely logical `l && r`, which also leaves an author a way to
ask for the old answer-the-right-operand behaviour deliberately.

## `OR` is alternation, made explicit

`AND` answers *every* operand; `OR` answers the *first available* one. That
was already roughly true — Elixir's `||` answers its left operand whenever
that operand is truthy — so this is not a change of meaning the way `AND`
was. What changes is that the algebra is now stated and applied over the
whole spine at once instead of pairwise:

    let pick = ?missing OR ?present            # "here"
    let pick = ?a OR ?b OR ?c                  # the first one the host sent

`false` and `nil` are the **identity** of disjunction and drop out. The first
operand carrying a value answers. When every operand is falsey there is
nothing to choose between them, so the *first* one answers — pairwise `||`
returned the *last*, and that single case is the whole observable behaviour
change.

`true` answers only when it is the first available operand. Strict duality
with `AND`, where a falsey operand is absorbing wherever it sits, would make
`(A) OR true` answer `true`; it answers `A`. Alternation is ordered, and a
fallback that discarded the value it was a fallback for would make `OR`
useless in value position.

`:or` and `:||` flatten into one spine. Unlike `AND` and `&&` there is no
divergence in meaning to preserve between the two spellings, because `OR` is
only becoming explicit about what `||` was already doing.

Evaluation stays eager over the whole spine: A-56 forbids short-circuiting,
since an operand may be a `[MODULE::verb]` call whose side effect is the
point, and that holds whether or not its value turns out to be reachable.

## Expression position invokes modules (A-56)

A `[MODULE::verb]` written where a *value* is expected — `if
[FILE::extension] eq "pdf"`, `let x = [PDF::title]`, `emit [EVENT::fire]`,
an argument of another call — is dispatched at the moment the expression is
evaluated, and the verb's return value *is* the value of the expression.
It is not also emitted as a separate operation; the call happens once.

**Evaluating an expression therefore has side effects, and that is
deliberate, not an oversight.** It follows directly from the decision that a
module call must have a usable return value: the value can only be had by
making the call, and the call is host code that may write to a device, a
file or a socket. The consequences bind anyone changing this module:

  * **Do not reorder expression evaluation.** Operand order is the order
    the calls happen in.
  * **Do not memoise or common-subexpression it.** Two occurrences of the
    same call are two calls. A call in a `while` condition is one call per
    iteration, including the final iteration that ends the loop. A call in
    a `for` body is one call per element.
  * **Do not short-circuit around it.** `and`/`or` here resolve both
    operands before combining them, so both sides' calls happen.

Dispatch goes through `Anemos.Runtime.Dispatcher.invoke_verb/5`, which is
the same function the statement path uses. That is the whole point of it
being shared: argument-schema validation, bounds, allow-lists and path
confinement (A-11) apply to a call in expression position exactly as they
do to one written as a statement. Calling `handle_verb/3` from here
instead would have been a fourth way to reach host code around a check.

The registry arrives in the evaluation context as `:registry`, and the
context to hand host code as `:_verb_context` — the same shape by which
`:data_store` already arrives for `memberof()`. Those keys are authority
for *evaluation*; they are not in `:_verb_context` and must never be
forwarded to a verb.

### When the verb fails

A failed call in expression position **aborts the rule body** and appends a
`%{type: :verb_error, error: error}` operation, which the dispatcher turns
into `{:error, error}` in the results list — the same place a
statement-position failure lands.

Substituting `nil` and carrying on was rejected. That is precisely the
A-25 shape: a guard comparing `nil` is merely false, so a `SECRET::unlock`
that refused and an unlocked secret that did not match would be
indistinguishable, and the rule would take its `else` branch as though it
had asked a question and got an answer. There is no value that honestly
represents "the call did not happen", so evaluation stops instead of
inventing one.

Aborting is also why operations the body computed *before* the failure are
kept: they are returned along with the error rather than discarded, so the
results list shows how far the rule got.

Condition bodies and capability bodies are given the same two keys and
dispatch the same way. A condition *predicate* is the one place with no
channel for an error — its answer is a boolean and nothing else — so a
failure there is logged and the condition answers false.

# `compile`

```elixir
@spec compile(Anemos.AST.Program.t()) ::
  {:ok, Anemos.CompilationResult.t()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Compile an AST into an `%Anemos.CompilationResult{}` containing compiled rules,
conditions, and capabilities.

Each rule with `when` blocks produces one `CompiledRule` per event subscription.
The handler closure takes `(event_name, context, persistent_bindings)` and
returns `{:ok, [operation], updated_persistent_bindings}`.
Persistent bindings hold `set` values that survive across firings.

Supported statement types: `let`, `set`, `log`, `emit`, `demand`, `if`,
`while`, `for`/`each`/`every`/`foreach`, `return`, `done`, `nextevent`,
`nextrule`, `context`, commands (`[MODULE::verb ...]`), and triple patterns.
Guard modifiers (`unless`, `until`) on `when`, `if`, and `at` blocks.

## `nextevent` and `nextrule` carry arguments

Both take an optional `with { key: expr }` block. The pairs are resolved
against the *sending* body's bindings and merged into the target's event
context, so the target reads them as `?key` exactly as it would read a real
event payload. Merged, not replaced: the target still sees the event that got
it there.

One resolver (`resolve_block_args/3`) and one merge
(the dispatcher's `with_block_args` helper) serve both statements. A
second path that mostly does what the first does, minus a check, is the shape
that accounted for four separate defects on this branch (A-39, A-59, and two
others), and a symmetry feature is where it gets introduced.

## Examples

    iex> {:ok, ast} = Anemos.Parser.parse("rule r { when EV { log \"hi\" } }")
    iex> {:ok, %{rules: [compiled]}} = Anemos.Compiler.compile(ast)
    iex> compiled.name
    "r"
    iex> compiled.subscriptions
    ["EV"]
    iex> {:ok, [%{type: :log, value: "hi"}], %{}} = compiled.handler.("EV", %{}, %{})

    iex> {:ok, ast} = Anemos.Parser.parse("rule r { when EV { set i = 0 while $i < 3 { set i = $i + 1 } log $i } }")
    iex> {:ok, %{rules: [compiled]}} = Anemos.Compiler.compile(ast)
    iex> {:ok, [%{type: :log, value: 3}], _} = compiled.handler.("EV", %{}, %{})

`AND` answers every operand and `OR` the first available one, which is easier
to read as code than as prose:

    iex> {:ok, ast} = Anemos.Parser.parse(~S|rule r { when EV { let x = (:h IN A "1") AND (:h IN AAAA "2") log @x } }|)
    iex> {:ok, %{rules: [compiled]}} = Anemos.Compiler.compile(ast)
    iex> {:ok, [%{type: :log, value: value}], _} = compiled.handler.("EV", %{}, %{})
    iex> value
    [["h", "IN", "A", "1"], ["h", "IN", "AAAA", "2"]]

    iex> {:ok, ast} = Anemos.Parser.parse(~S|rule r { when EV { let x = (:h IN A "1") OR (:h IN AAAA "2") log @x } }|)
    iex> {:ok, %{rules: [compiled]}} = Anemos.Compiler.compile(ast)
    iex> {:ok, [%{type: :log, value: value}], _} = compiled.handler.("EV", %{}, %{})
    iex> value
    ["h", "IN", "A", "1"]

---

*Consult [api-reference.md](api-reference.md) for complete listing*

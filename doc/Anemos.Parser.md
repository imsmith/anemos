# `Anemos.Parser`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/parser.ex#L1)

Recursive descent parser for the Anemos DSL.

Consumes the token stream from `Anemos.Lexer.tokenize/1` and produces
an `Anemos.AST.Program` struct.

Supported declarations: `rule`, `condition`, `capability`, `data`, `query`,
and source-level `signed_by` (A-60).

Supported trigger blocks: `when`, `if`, `at`, `context`.
Guard modifiers: `unless`, `until` (on `when`, `if`, `at`).

Supported statements: `let`, `set`, `log`, `emit`, `demand`,
`while`, `for`, `each`, `every`, `foreach`,
`return`, `done`, `nextevent`, `nextrule`,
and `[MODULE::verb ...]` command expressions.

## `parse/1` is total, and that is a security property

For **any** binary, `parse/1` answers `{:ok, %AST.Program{}}` or
`{:error, message}`. It does not raise, and it terminates.

This is not tidiness. `parse/1` is the only path from source text to an AST —
`Anemos.Runtime.LoadAuthority.gate/3` runs it *before* deciding whether the
source may be trusted — and under the multi-tenant decision that text is
untrusted input. Every caller matching `{:error, _}` gets an exception
instead if a clause is missing, and a truncated or hostile `.rule` file is
exactly the input this boundary is most likely to meet.

Totality has been broken three times (A-65, A-74, A-75), so the rule is
written down:

> **Whoever knows what must come next owns the end-of-input check.**

A function that dispatches on token shape must therefore be total over
*both* an empty token list **and** a token it does not expect. Missing either
is the same defect: `collect_simple_list/2` had its `[]` clause and still
crashed, on a token type it had no clause for (A-75).

The converse matters too, or the rule just breeds dead code. Where a caller
selects a function by matching the token itself, the caller has already
answered and the callee must *not* answer again. Exactly three functions here
have no `[]` clause for that reason — `parse_declaration/1`,
`parse_bracket_expr/1` and `parse_format_block/1` — and each carries a
comment saying which caller answered, so a totality sweep does not "fix"
them. When in doubt, add the clause and let Dialyzer adjudicate: it reports
an unreachable pattern, which is precisely the question being asked (A-71).

Both classes are covered by tests rather than by inspection —
`Anemos.ParserTruncationTest` sweeps every prefix of every shipped example,
and `Anemos.ParserFuzzTest` mutates them.

# `parse`

```elixir
@spec parse(String.t()) ::
  {:ok, Anemos.AST.Program.t()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Parse a source string into an AST.

Returns `{:ok, %Anemos.AST.Program{}}` or `{:error, message}`.

## Examples

    iex> {:ok, %Anemos.AST.Program{declarations: [rule]}} =
    ...>   Anemos.Parser.parse("rule test { when EVENT { log \"hello\" } }")
    iex> rule.name
    "test"
    iex> [%Anemos.AST.When{event: "EVENT", body: [%Anemos.AST.Log{}]}] = rule.body

    iex> {:error, %Comn.Errors.ErrorStruct{code: "anemos.parser/syntax_error"}} =
    ...>   Anemos.Parser.parse("rule { }")

A source-level `signed_by` is a declaration in its own right, so a file
carrying no `rule` can still make a provenance claim (A-60):

    iex> {:ok, %Anemos.AST.Program{declarations: declarations}} =
    ...>   Anemos.Parser.parse("signed_by :operator\ncondition c { when EV { log \"x\" } }")
    iex> Enum.find(declarations, &match?(%Anemos.AST.SignedBy{}, &1))
    %Anemos.AST.SignedBy{signer: "operator", line: 1}

Truncated input returns an error rather than raising. `parse/1` is total over
binaries because it runs before the trust boundary, not after it:

    iex> {:error, error} = Anemos.Parser.parse("rule r { when")
    iex> error.message
    "Expected event name after 'when' but got end of input"

    iex> {:ok, %Anemos.AST.Program{declarations: []}} = Anemos.Parser.parse("")

---

*Consult [api-reference.md](api-reference.md) for complete listing*

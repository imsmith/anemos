# 3. Values and expressions

A policy spends much of its life naming values, testing them, and passing them
to commands. This chapter gives those everyday operations precise meanings.

## Literal values

```anemos
rule values {
  when EXAMPLE {
    log "a string"
    log 42
    log 3.5
    log true
    log false
    log :garage.light
    log eth0
  }
}
```

Numbers are decimal integers or floats. Strings use double quotes and support
`\"`, `\\`, `\n`, and `\t`. Booleans are the lowercase words `true` and
`false`. A missing external value is represented by host `nil`; writing the
bare word `nil` in a policy does not create that value.

Colon-prefixed symbols such as `:garage.light`, bare identifiers such as
`eth0`, and uppercase names in value position all evaluate to strings.
Anemos symbols are not dynamically created Elixir atoms. For example,
`:garage` and `"garage"` have the same runtime value. Prefer quoted strings
for arbitrary text and symbols for stable labels or fact identifiers.

Unquoted addresses such as `192.0.2.1` and `2001:db8::1` have lexer support
in appropriate positions; quote addresses passed as ordinary command data
to avoid ambiguities with qualification and time syntax. Durations and time
literals are described in Chapter 7.

The language has no general JSON-style map or square-bracket array literal.
Square brackets are for commands and triple patterns. Collections normally
come from event data, module results, pipelines, or value compounding. A
parenthesized sequence such as `(:host IN A "192.0.2.1")` is a list-valued
pattern, explained below.

## Names and punctuation

Ordinary identifiers begin with a lowercase letter and may contain letters,
digits, underscores, hyphens, and dots. Thus `garage-lights` is one name,
not subtraction. Write spaces around arithmetic operators, especially `-`.
Module/event names use uppercase forms such as `DEVICE` and `MOTION_DETECTED`;
names like `CONDITION_ready` have a supported lowercase tail.

Variable references have a narrower spelling: after `?`, `@`, or `$`, use
letters, digits, and underscores, with a letter or underscore first. Dots in
`?user.name` are not a general map-navigation operator. Have the host expose
flat keys such as `user_name`, or use a module/query to navigate structured data.

Data and query declarations may have hyphenated names; since sigil references
cannot address those names as a whole, use underscore names when you intend
to read a declaration through `?name`.

Keywords and operators are reserved in many positions. Give bindings simple,
descriptive names such as `reading`, `enabled`, or `total`; avoid keywords
such as `state`, `source`, `map`, and `query` as binding names.

## Binding and reading

```anemos
rule temperature {
  when READING {
    let celsius = ?temperature
    let fahrenheit = @celsius * 9 / 5 + 32
    set latest = @fahrenheit
    log $latest
  }
}
```

With a numeric temperature of `20`, this logs `68.0`. `let` evaluates its
right side once and binds a value for this handler. `set` updates persistent
state. Write the plain binding name after the keyword; use its sigil when
reading it. `let celsius` creates `@celsius`, not `$celsius` or `?celsius`.

The term *immutable* is used for `let` bindings to distinguish them from
persistent mutable state. The current evaluator permits a later `let` with
the same name to replace the local binding. Write single-assignment `let`
code so the intended lifetime stays clear; use `set` for intentional updates.

The compiler rejects an `@name` or `$name` never bound anywhere in its
declaration. This catches wrong sigils and typos. It does not prove a binding
exists on every execution path. Reading `$count` before its first executed
`set count` still yields `nil`.

For `?name`, lookup first checks the dispatch's context data, then a named query
visible to the rule, then a visible data block. If none exists, it yields
`nil`. Context data can shadow a query or dataset. Choose payload field names
and declaration names accordingly.

## Truth and comparison

Only `false` and `nil` are falsey. Zero, empty strings, empty lists, and empty
maps are truthy. Consequently `if ?items` is a presence/truthiness check, not
an emptiness check. `exists` tests non-`nil`, so `exists ?flag` is true even
when `?flag` is boolean false.

| Operation | Spellings | Meaning |
| --- | --- | --- |
| Equality | `==`, `eq` | Compare values; integer and equal float compare equal |
| Inequality | `!=`, `ne` | Negated equality |
| Strict equality | `===`, `!==` | Also distinguish integer from float |
| Order | `<`, `<=`, `>`, `>=`; `lt`, `le`, `gt`, `ge` | Compare operands |
| Negation | `not`, `!` | Boolean negation of truthiness |

Comparison does not convert strings to booleans or numbers: `"1" == 1` is
false and `"true" == true` is false. Comparing a boolean to a boolean-shaped
string with ordinary equality/inequality logs a mismatch warning. Relational
comparison uses host term ordering for mixed types; ensure both operands have
the expected type before relying on a numeric threshold.

Use `infer ?value` as an inspection statement when you are unsure what the
host supplied. It reports a kind such as `string`, `number`, `list`, `map`,
`secret`, or `nothing`.

## Arithmetic, bitwise, and string operations

`+`, `-`, `*`, `/`, and `%` provide arithmetic. Division produces a float;
remainder requires integers. `&`, `|`, `^`, `<<`, `>>`, and unary `~` operate
on integers. `^` is bitwise XOR, not exponentiation. Unary minus is not
implemented; write `0 - 5` for a negative constant or receive a negative
number from host data.

```anemos
rule arithmetic {
  when EXAMPLE {
    log 2 + 3 * 4
    log (2 + 3) * 4
    log 5 % 2
    log 5 & 3
    log 1 << 3
    log 0 - 5
  }
}
```

The values are `14`, `20`, `1`, `1`, `8`, and `-5`.

`contains`, `starts_with`, `ends_with`, and `matches_regex` test strings:

```anemos
rule filenames {
  when FILE_SEEN {
    if ?path ends_with ".pdf" {
      log "PDF candidate"
    }
    if ?name matches_regex "^[a-z]+$" {
      log "lowercase name"
    }
  }
}
```

Regex patterns are strings, not slash-delimited literals. Escape backslashes
for the string layer. Invalid regexes fail at evaluation time. `matches_glob`
is recognized by the parser but has no working evaluator; use a regex or a
host verb. `++` is tokenized but is not implemented string concatenation.
General string interpolation is also not implemented. Build formatted text in
a host module when a fixed message and separate value logs are insufficient.

`in` and `notin` test list membership. `memberof(dataset)` checks a named
dataset (Chapter 8). These operators bind unusually loosely: when combining
membership with logical tests, parenthesize each test, for example
`(?name in ?names) AND (?enabled == true)`.

## Logical operators also carry values

For boolean operands, `AND`/`and` and `OR`/`or` behave as conjunction and
disjunction. With other values, `AND` compounds operands and `OR` chooses
the first available one:

```anemos
rule records {
  when UPDATE {
    let records = (:host IN A "192.0.2.1") AND (:host IN AAAA "2001:db8::1")
    log @records
    let selected = ?preferred OR ?fallback
    log @selected
  }
}
```

The first log value is the list:

```elixir
[["host", "IN", "A", "192.0.2.1"],
 ["host", "IN", "AAAA", "2001:db8::1"]]
```

Inside a parenthesized multi-value pattern, `IN` is data. The pattern is
preserved as a list rather than evaluated as a membership test. Do not confuse
this record-building form with ordinary `value in collection` expressions.

An `AND` chain preserves each non-boolean operand as one list element; it
does not flatten a list operand's contents. `true` contributes no value. Any
`false` or `nil` absorbs the chain and becomes its answer; the first such
operand wins. With one non-boolean value and otherwise `true`, the answer is
that value, not a singleton list. An all-true chain answers `true`.

`OR` discards falsey choices and answers the first truthy operand. If all
operands are falsey, it answers the first operand. `||` is the same alternation
operator. `&&` retains its separate behavior: it answers its left operand if
falsey, otherwise its right operand. It does not compound values.

**Evaluation is eager.** Both operands of these operators are evaluated even
when the answer can already be determined. `?cached OR [CACHE::fetch]` calls
`CACHE::fetch` even when `?cached` has a value. Use an `if` when you need to
avoid a call. A condition such as `false AND [DEVICE::set ...]` still invokes
the value-position command.

## Precedence

Multiplication binds more tightly than addition, and comparisons more tightly
than logical operators. Parentheses override precedence. Membership/string
tests bind less tightly than logical operators; this differs from many familiar
languages. The [full precedence table](reference.md#operator-precedence) gives
every level. Parenthesize mixed tests for readers as well as for the parser.

## Exercises

1. What is `0 OR 7`? What is `false OR 7`?
2. What is `"a" AND "b" AND "c"`? What is `"a" && "b"`?
3. How do you avoid calling `LOOKUP::read` when `?cached` exists?

Answers: (1) `0` and `7`. (2) `["a", "b", "c"]` and `"b"`.
(3) Branch on `exists ?cached`; place the call only in the other branch.

[Next: Decisions and control flow](04-control-flow.md) · [Contents](README.md)

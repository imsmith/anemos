# Introspection statements

**Date:** 2026-10-03 · **Branch:** `introspection`

## Problem

The language reserves `show`, `list`, `graph`, `trace`, `explain`,
`exists`, `infer` and `assert` — the lexer has had them as keywords from
the start — and the parser rejects every one. The PRD gives each a
phrase. The runtime side exists since item 1 (`describe/1`, `explain/3`,
`trace/2`); a rule cannot ask any of it.

## Ground

Comn's four verbs are the discovery loop the Anemos design drew:
**look** (what is this?), **recon** (what can it do?), **choices** (what
are my options?), **act** (do it). `act` is `[MODULE::verb]`. The other
three are what a rule asks of a thing before acting on it, and that is
what the statements are:

| statement | asks | of a module | of an event | of a value |
| --- | --- | --- | --- | --- |
| `show X` | look | its `look/0` | how many rules and conditions listen | the value, shown |
| `explain X` | recon | its `recon/0` | what dispatching it would reach (`Runtime.explain`) | its kind and shape |
| `list X` | choices | its verbs (`choices/0`) | the rules that listen | its elements, or a map's keys |
| `exists X` | — | registered? | anything listening? | bound and not nil? |

`graph X` answers the triples whose subject or object is `X`. `infer X`
answers what the runtime knows about `X`'s kind: `string`, `number`,
`list`, `map`, `secret`, `nothing`. `trace X` records `X`'s value in the
dispatch trace, which keeps no other value but a `log`'s. `assert X`
records that `X` held, or that it did not and the rule stopped there.

Every statement is an operation in the dispatch results, carrying what it
found under `value`, and in the trace. That is where a console, a view,
or a test reads them.

## Subjects

After the keyword, a subject is one of:

- a `NAME` (a module id token): a module if one is bound to it, else an
  event if anything listens for it, else nothing. Modules and events share
  the alphabet; the runtime says which it found.
- a catalogue word: `rules`, `conditions`, `modules`, `events`,
  `policies`, `schedules`. `list rules` names them; `show rules` counts
  them; `explain rules` is `describe/1`'s entry for each.
- an expression: a value.

`exists X` is also an expression, so `if exists ?serving_host { ... }`
reads as it should. In that position `X` is a variable or a module; an
event's listeners are the dispatcher's to know, and an expression is
evaluated before the dispatcher sees the result.

## How a module answers

A module that implements `Comn` (as the shipped example modules do)
answers `look`, `recon` and `choices` itself. One Elixir module bound under
many names — the substrate bridge — implements the optional
`Anemos.Runtime.Module.describe/1` and answers per name. A module with
neither gets a card from what the runtime knows: its name, its Elixir
module, and the verbs it declared with `use Anemos.Module`.

## Rulings

1. **Statements, not a console.** The console is a view over the trace,
   and the agento Rules view already is one.
2. **Introspection values are kept in the trace.** The author wrote the
   statement to see the value; the trace is where it is seen.
3. **A failed `assert` stops the rule, like `done`,** and says so in the
   results. It does not stop the dispatch: other rules still run.
4. **A string is a value, never a name.** `explain "garage-lights"`
   explains the string. Names are written bare.

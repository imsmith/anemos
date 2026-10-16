# Programming Anemos

An introduction, practical guide, and language reference for Anemos 0.1.0.

Anemos expresses automation as policies: when something happens, decide what
it means and ask the host application to act. A policy might turn on a light,
classify a connection, or arrange a batch of documents for processing. The
language supplies events, decisions, state, and composition. The application
that embeds it supplies access to the outside world.

This book assumes no knowledge of Anemos. You should be comfortable editing a
text file and running a terminal command. The first half teaches policy writing
without requiring Elixir. The integration chapters introduce the Elixir needed
to run a persistent interpreter and supply your own commands.

## Reading the book

Read Chapters 1–4 in order. They establish the execution model that makes the
rest of the language understandable. Then follow your application: Chapter 5
for batches, Chapter 6 for stateful events, Chapter 7 for time, and Chapter 8 for
shared data. Chapters 9–11 cover embedding, operation, and troubleshooting.
Chapter 12 combines those ideas in a complete application you can run and adapt.
The reference and index are intended for return visits.

| Part | Chapter | What you will learn |
| --- | --- | --- |
| Getting started | [1. Your first policy](01-first-policy.md) | Install, run, change, and diagnose a complete program |
| Getting started | [2. How policies run](02-execution-model.md) | Events, listeners, contexts, state, and operation order |
| The language | [3. Values and expressions](03-values-and-expressions.md) | Names, sigils, types, operators, and compounding |
| The language | [4. Decisions and control flow](04-control-flow.md) | Branches, guards, early exits, and handoffs |
| The language | [5. Collections and pipelines](05-collections.md) | Loops, filtering, mapping, and reduction |
| Stateful automation | [6. Conditions and capabilities](06-conditions-and-capabilities.md) | Remembered reports, transitions, and on-demand work |
| Stateful automation | [7. Time and duration](07-time.md) | Dwell timers, intervals, dates, and recurring schedules |
| Data | [8. Datasets, queries, and facts](08-data.md) | Membership, data handlers, live feeds, and triple patterns |
| Applications | [9. Embedding and extending Anemos](09-embedding.md) | Runtime setup, commands, events, channels, and secrets |
| Applications | [10. Deploying and operating policies](10-operation.md) | Replacement, watching, signing, recovery, and limits |
| Applications | [11. Finding and fixing problems](11-troubleshooting.md) | Reports, introspection, tracing, and practical recipes |
| Putting it together | [12. Workshop temperature alerts](12-workshop.md) | Build and test a complete application with a host service |
| Reference | [Language and API reference](reference.md) | Syntax summaries, precedence, defaults, and feature status |
| Reference | [Glossary and subject index](glossary.md) | Definitions and direct routes back to explanations |

## Conventions and example files

Complete policies appear in `anemos` code blocks. Each is independent unless
the surrounding text says otherwise. The documentation test parses and compiles
every such block. Syntax templates and deliberately incomplete fragments use
`text` blocks. Shell commands use `sh`; host application code uses `elixir`.
Angle brackets in templates mark a placeholder you must replace; they are not
literal Anemos syntax.

Downloadable example files accompany the first chapters. Run commands
from the repository root. The [walkthrough script](examples/walkthrough.exs)
executes the persistent counter, dataset, and pipeline examples and checks their
answers:

```sh
mix run docs/manual/examples/walkthrough.exs
```

Exercises ask you to predict a result before running a change. Answers follow
the exercises, so you can check your reasoning without needing another book.

## What this edition promises

This edition describes the implementation in this repository, version 0.1.0.
Examples distinguish working language features from syntax that is only parsed
or only partly implemented. In particular, read the qualifications about
`demand`, `until`, triple queries, and pipeline `emit` before depending on them.
The [feature-status reference](reference.md#feature-status) collects those
qualifications in one place.

The design notes under `docs/design-notes/`, historical Tcl sketches, and some
older examples discuss a broader language. They are useful background, but they
are not the contract taught here. Host modules also have their own contracts:
the spelling `[DEVICE::set ...]` says how to call a command, not what hardware
exists or whether a command has permission to operate it.

Documentation checks live in `test/anemos/manual_test.exs` in the checkout.
They check complete policy syntax and selected behavioral promises. They do not
turn an application-specific module, data format, or external service into a
built-in feature.

Continue with [Chapter 1: Your first policy](01-first-policy.md).

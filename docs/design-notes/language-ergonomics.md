# Language Design Principles

## Vault Source

- `097 Orders of the System/99 Conversations with the Ghost/Designing Ergonomic Languages.md`

Derived from Steven Pinker's _Words and Rules_ and applied to DSL design.

## Core Principles

### 1. Rules First, Exceptions Explicit

Use consistent patterns for 80-90% of language features. Allow escape hatches (macros, raw expressions) for irregular cases. Regular cases should be composable by rules; irregular ones handled with explicit constructs.

### 2. Self-Similar Syntax

Similar constructs should look and feel the same. Declarations, definitions, and invocations should be structurally consistent. Users should generalize syntax from one domain to another.

### 3. Chunkable and Memorable

Design around natural groupings: noun-verb-object, subject-predicate-value. Keep constructs short enough for working memory (~7 +/- 2 elements). Frequently used phrases should feel like idioms.

### 4. Default + Override Pattern

Provide reasonable defaults for all constructs. Allow local overrides without disrupting global behavior. Clear, consistent syntax for overrides.

### 5. Transparent Morphology

New concepts built using visible, consistent transformations. Compound constructs should be transparent in meaning. Avoid syntactic noise -- every symbol must carry semantic weight.

### 6. Forgiving, Discoverable Errors

Error messages should suggest corrections. Users should safely guess syntax. The parser should guide users toward correct patterns.

### 7. Domain Terms Are First-Class

The language should reflect domain vocabulary. Operations phrased using domain verbs. A snippet should be understandable without being a programmer.

### 8. Composability Over Cleverness

Rules and constructs combine simply. Clever shorthand is opt-in. Clear mental model behind composition (pipeline, tree, graph, scope).

### 9. Small Core, Rich Vocabulary

Small, well-defined core grammar. Richness via user-defined or domain-defined vocabulary, not grammar overloading. The language grows without breaking existing mental models.

## Design Patterns

| Pattern | Format | Use Case |
|---------|--------|----------|
| Verb Phrase | `noun.verb(object)` | Actions on named things |
| Declarative Block | `thing { key: val }` | Structured configuration |
| Rule + Exception | `default + rule override` | Security, access, validation |
| Composable Chain | `data \|> step1 \|> step2` | Pipelines, transforms |
| Guessable Defaults | Omit to get convention | Reduce verbosity |
| Override-by-Naming | Named args for customization | Direct modification |

## Learnability Test

Can a beginner make a reasonable guess at how to express a new idea? Do users form correct intuitions before reading docs? Would a 10-year-old with domain exposure understand a basic example?

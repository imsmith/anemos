# Modal Logic Reference for DSL

## Vault Sources

- `097 Orders of the System/99 Conversations with the Ghost/meshPolicy - development.md`
- `097 Orders of the System/96 Standards/MeshPolicy Modal Specification (EBNF Draft).md`

## Modal Operators

| Symbol | Name | Meaning |
|--------|------|---------|
| `necessary` | Necessity | It must be the case |
| `possible` | Possibility | It could be the case |
| `impossible` | Impossibility | It cannot be the case |
| `O` | Obligation | It is required |
| `P` | Permission | It is allowed |
| `forbidden` | Prohibition | It is not allowed |
| `K` | Knowledge | It is known |
| `B_all` | Belief (general) | It is believed by everyone |
| `B_x` | Belief (by agent) | It is believed by agent x |
| `was` | Past | It was the case |
| `always_was` | Past (universal) | It has always been the case |
| `will_be` | Future | It will be the case |
| `always_will_be` | Future (universal) | It will always be the case |

## EBNF Grammar (Core)

```ebnf
policy         = modality, space, statement, reference, result ;
modality       = necessity | possibility | impossibility
               | obligation | permission | prohibition
               | knowledge | belief | temporality ;

statement      = quoted_text ;
reference      = "=", space, uri ;
result         = space, ".", space, uuid ;
```

See the full grammar in the vault source for belief-by-agent syntax, temporal modifiers, and extended fields (narrative, scope, justification).

## Extended Fields (Updated EBNF)

The updated specification adds:

- **narrative** -- full human sentence explaining the rule
- **scope** -- namespace limiting applicability
- **justified-by** -- UUID chain linking to epistemic or legal foundations
- **temporal** -- time-scoped validity

## How Modal Logic Relates to the Automation DSL

The `it` trigger block in the Automation DSL is the bridge to modal logic:

```
it <modal-ref> {
  <modal-body>
}
```

This allows rules to fire based on modal conditions (belief states, knowledge assertions, obligations). The `it` block is NOT in v0.1.0 -- see [future-features.md](future-features.md).

## Conflict Resolution via Modality

When policies conflict:

- Obligations override permissions (`O` > `P`)
- Prohibitions override permissions (`forbidden` > `P`)
- Trust score and timestamp break ties between same-modality conflicts
- Time-bounded policies expire and are ignored after their window

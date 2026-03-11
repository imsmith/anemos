# CommonRule Policy Language

## Vault Sources

- `097 Orders of the System/40 Doctrine/commonrule.md`
- `097 Orders of the System/96 Standards/CommonRule.md`
- `097 Orders of the System/99 Conversations with the Ghost/meshPolicy - development.md`

## What It Is

CommonRule is a declarative, modal, semantic policy language for encoding constraint, permission, belief, and time-scope within sovereign systems. It replaces brittle ACLs and ad hoc config files with explainable, verifiable policy statements grounded in modal logic.

## Core Concepts

A CommonRule policy statement has this structure:

```
MODALITY "statement" REFERENCE RESULT
```

Example:

```
O "All artifacts must include a :created_at timestamp" = https://mesh.standards.io/timestamp . 4d30c9be-913d-44ae-9956-983f2441edfd
```

Each policy carries:

- **Modality** -- the modal operator (obligation, permission, prohibition, etc.)
- **Statement** -- plain-text policy condition
- **Reference URI** -- linked standard or justification
- **Result UUID** -- immutable identifier
- Optional: scope, narrative, justification chain, expiry, author, belief context

## Enforcement Model

Every enforcement step follows:

1. **Match** -- does this object fall under the scope of a rule?
2. **Evaluate** -- is the policy valid now? Is it expired?
3. **Resolve** -- do any other policies conflict? Which takes precedence?
4. **Enforce** -- permit, deny, warn, or annotate accordingly.

## Conflict Resolution

Conflicts between rules are resolved using:

- Trust score of the issuer
- Timestamp precedence
- Policy modality (obligations override permissions)
- Time bounds (expired policies are ignored)
- Explicit precedence declarations via `justified-by` chains

## Serialization

CommonRule supports EBNF-defined grammar, YANG data models for machine validation, EDN for signed policy bundles, and content-negotiated API interaction.

## Relationship to Anemos

CommonRule defines **what should be true**. Anemos compiles those policies into executable convergence loops. See [anemos-orchestration.md](anemos-orchestration.md) for the full coordination model.

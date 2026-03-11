# Anemos Orchestration Engine -- Triangle of Intent

## Vault Source

- `097 Orders of the System/99 Conversations with the Ghost/XAML vs XUL Comparison.md` (section: "The Triangle of Intent")

## The Triangle

Three systems operate in parallel, coordinated through a shared semantic graph (the Reflexive Interactive Graph / RIG):

### CommonRule: What Should Be True

- Declarative, expressive policy language
- Anchors intent in auditable, human-readable logic
- Defines rights, obligations, conditions, and scope

### Anemos: What Will Be Done About It

- Policy-driven orchestration layer
- Converts **policy + reality** into a **residual state**
- Reconciles intent with current truth through directed action
- Delegates to agents, humans, or schedulers
- Maintains convergence pressure and tracks operational truth

### Sentinel: What Must Be Known About It

- Reflexive situational monitor
- Infers heuristic expectations and anomalies
- Simulates, alerts, audits, and narrates
- Thinks in terms of temporal patterns, soft thresholds, trust posture, scenario deviation

## Parallel Evaluation

| Role | Function |
|------|----------|
| CommonRule | Codifies norms and policies declaratively |
| Anemos | Compiles policies into residual convergence loops and executes them |
| Sentinel | Builds narrative expectation models and raises exceptions or insights |

## Flow

1. **Policy declared** (CommonRule): "All critical services must emit health telemetry every 5s."
2. **Anemos** checks system graph, builds residual delta for non-conforming services, schedules enforcement.
3. **Sentinel** watches for anomalies, cross-links to past incidents, projects risk.
4. **RIG** logs all edges: policy -> action -> outcome -> narrative.

## Key Insight

> Truth is enforced by Anemos.
> Meaning is revealed by Sentinel.
> Authority is grounded in CommonRule.

The triad is composable: Anemos residual functions can be expressed as CommonRules, Sentinel anomalies can become policies with epistemic qualifiers, and CommonRule fragments can be generated from learned expectations (policy induction).

## RIG Namespace Conventions

- `policy.*` -- declarative intent, doctrine, expectations
- `meta.*` -- execution, events, telemetry, forensic evidence

Examples: `policy.infosec.encrypt-pii`, `meta.event.audit:20250604-1830Z`

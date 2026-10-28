# Glossary and subject index

## Glossary

**Binding.** A name associated with a value. A `let` creates an `@` binding;
a `set` creates a `$` binding. See [values](03-values-and-expressions.md#binding-and-reading).

**Flow.** A stored, ordered workflow of `nextrule` steps, run as a whole by
`flow <name>` from a rule body. Halts at the first failing step. See
[flows](04-control-flow.md#run-a-stored-flow).

**Capability.** A passive named `on demand` body. Its context restricts which
declaration may demand it. Current dispatch has important stack/execution
limits. See [capabilities](06-conditions-and-capabilities.md#define-work-to-perform-on-demand).

**Channel.** A named output destination handled by the current host connector.
It is distinct from an internal event subscription. See [channels](09-embedding.md#emit-values-and-connect-a-channel).

**Command.** A bracketed module/verb invocation. In value position it executes
during evaluation; in statement position it becomes a queued operation.
See [operation order](02-execution-model.md#bodies-evaluate-then-operations-execute).

**Compound.** The collection formed by value-level `AND`, preserving operand
boundaries. See [compounding](03-values-and-expressions.md#logical-operators-also-carry-values).

**Compound trigger.** A remembered-state `AND` or `OR` over event reports.
It differs from value-level compounding. See [reports](06-conditions-and-capabilities.md#combine-reports-in-a-rule).

**Condition.** A named boolean state reevaluated on subscribed events. Its
false-to-true transition generates `CONDITION_<name>` and evaluates transition
actions. See [conditions](06-conditions-and-capabilities.md#name-a-continuing-condition).

**Context data.** Values available to `?` lookup from the current dispatch's
payload map. The host can merge defaults into that map. See [event input](09-embedding.md#supply-event-data).

**Context path.** A dotted location used for listener and capability boundary
checks. Whole segments determine containment. See [boundaries](02-execution-model.md#a-context-belongs-to-a-listener).

**Dataset.** Named reference data used for exact membership or read through
`?name`. Simple datasets are sets. See [datasets](08-data.md#a-named-dataset).

**Declaration.** A top-level named language definition, such as a rule or
query. See [source structure](reference.md#source-structure).

**Dispatch.** Delivering an event through subscription selection, context
filtering, handler evaluation, and operation execution. See [execution model](02-execution-model.md).

**Dwell.** A duration for which a reported trigger state must remain true
before a handler runs. See [dwell timers](07-time.md#wait-for-a-reported-state-to-persist).

**Envelope.** A published value plus type, source, time, label, and channel.
See [emission](09-embedding.md#emit-values-and-connect-a-channel).

**Event.** An exact name, optional context path, and payload supplied by a
producer. A name such as `SENSOR::motion` is still an event until bracketed as
a command. See [names](02-execution-model.md#the-four-kinds-of-name).

**Falsey.** Boolean `false` or host `nil`. All other values, including zero
and empty collections, are truthy. See [truth](03-values-and-expressions.md#truth-and-comparison).

**Guard.** A trigger/block modifier such as `unless`, evaluated before its
body. See [guards](04-control-flow.md#skip-a-trigger-with-unless).

**Handler.** The executable body selected for a trigger. Several handlers may
belong to one named rule and share its persistent binding state.

**Host.** The Elixir application embedding Anemos, supplying command modules,
event producers, adapters, and operational guarantees. See [embedding](09-embedding.md).

**Load authority.** Host policy that admits/refuses source before compilation
and installation. See [authorization](10-operation.md#authorize-policy-loads).

**Module.** A registered collection of host verbs, addressed by a name such as
`MATH`. It is not defined in policy source. See [extension](09-embedding.md#define-a-real-command-contract).

**Operation.** A descriptor produced during body evaluation for the dispatcher
to execute or report. Not every evaluated expression produces an operation.

**Partial load.** A source installed with some inert declarations, reported as
`{:partial, failures}`. See [load outcomes](10-operation.md#handle-all-three-load-outcomes).

**Payload.** The data accompanying an event; normally a map with string keys.

**Persistent binding.** A `$` value retained across firings of one named rule,
within the runtime's lifetime. See [state](02-execution-model.md#state-has-a-lifetime-and-an-owner).

**Pipeline.** An expression passing a collection/value through `|>` stages.
See [pipelines](05-collections.md#filter-map-reduce).

**Policy.** A source unit containing declarations. Named deployments give it
an ID used for replacement and unload. See [deployment](10-operation.md).

**Query.** A named host-engine computation invoked through `?name`, with
expected inputs and a named output. See [queries](08-data.md#queries-name-a-computation).

**Report.** What `when` takes: an event with a truth at the moment it
arrives, which stands until the next report of the same event. Compound
listeners, dwell and conditions work on reports. Contrast *Interaction*.

**Interaction.** What `on` takes: an occurrence such as boot, shutdown, a
keypress or a login. It has no truth, is never remembered, and fires once per
occurrence. See [reports and interactions](02-execution-model.md#a-report-and-an-interaction).

**Rule.** A named collection of event/time handlers, context, state, and
optional local data/query declarations. See [first policy](01-first-policy.md).

**Runtime.** A supervised interpreter with installed policies, registered host
modules, in-memory state, dispatcher, and scheduler.

**Sigil.** A prefix (`?`, `@`, `$`) selecting how a value name is read.

**Transclusion.** A data declaration's request to derive another representation;
the handler performs it with `transduce/3`. See [structured data](08-data.md#structured-data-belongs-to-a-handler).

**Triple.** A subject–predicate–object fact stored in the runtime's shared
triple store. See [facts](08-data.md#facts-and-triple-patterns).

**Verb.** An operation name implemented by a host module, such as `double` in
`MATH::double`.

## Subject index

| Find | Read |
| --- | --- |
| `?`, `@`, `$` | [Binding rules](03-values-and-expressions.md#binding-and-reading) |
| `AND`, `OR`, `&&`, `\|\|` | [Value algebra](03-values-and-expressions.md#logical-operators-also-carry-values), [event algebra](06-conditions-and-capabilities.md#combine-reports-in-a-rule) |
| Argument validation and filesystem roots | [Module boundary](09-embedding.md#validate-inputs-at-the-module-boundary) |
| Application walkthrough | [Workshop alerts](12-workshop.md) |
| Assertions and early exit | [Stop a handler](04-control-flow.md#stop-a-handler-early) |
| Boolean/string mismatches | [Truth and comparison](03-values-and-expressions.md#truth-and-comparison) |
| CLI flags and exit codes | [CLI reference](reference.md#command-line-reference) |
| Context denial | [Boundaries](02-execution-model.md#a-context-belongs-to-a-listener), [diagnosis](11-troubleshooting.md#common-symptoms) |
| Counter initialization | [State ownership](02-execution-model.md#state-has-a-lifetime-and-an-owner) |
| Data handler implementation | [Complete handlers](09-embedding.md#supply-a-complete-data-handler) |
| Demand flags | [Integration limits](06-conditions-and-capabilities.md#demand-flags-and-the-current-integration-limit) |
| Emit labels and connectors | [Emission](09-embedding.md#emit-values-and-connect-a-channel) |
| Empty results | [One-shot diagnosis](11-troubleshooting.md#diagnose-a-one-shot-run) |
| Event protocol and map shapes | [Event input](09-embedding.md#supply-event-data) |
| Examples to run | [First policy](01-first-policy.md), [scripts](README.md#conventions-and-example-files) |
| `exists`, `infer`, `show`, `explain`, `list` | [Policy inspection](11-troubleshooting.md#inspect-from-a-policy) |
| Feature gaps and reserved syntax | [Feature status](reference.md#feature-status) |
| `for`, `each`, `every`, `foreach`, `while` | [Collections](05-collections.md) |
| `if`, `elseif`, `else` | [Branches](04-control-flow.md#branch-on-a-value) |
| Loading/reloading/unloading | [Operation](10-operation.md#give-deployed-sources-stable-identities) |
| Membership / CIDR caveat | [Datasets](08-data.md#a-named-dataset) |
| `nextevent`, `nextrule`, `with` | [Handoffs](04-control-flow.md#hand-work-to-another-event) |
| Operator precedence | [Full table](reference.md#operator-precedence) |
| Persistent state, reset, and recovery | [State ownership](02-execution-model.md#state-has-a-lifetime-and-an-owner), [recovery](10-operation.md#understand-recovery-boundaries) |
| Query inputs / output | [Query contract](08-data.md#queries-name-a-computation) |
| Schedules, NLD, time zones | [Time](07-time.md) |
| Secrets and redaction | [Wrapped credentials](09-embedding.md#keep-credentials-wrapped) |
| Signing and `signed_by` | [Signed source](10-operation.md#verify-signed-source) |
| Tracing and explain API | [Runtime observation](11-troubleshooting.md#ask-what-the-runtime-holds) |
| `unless`, `until`, run once | [Guards](04-control-flow.md#until-and-stopping-permanently) |
| Watcher and signature sidecars | [Directory deployment](10-operation.md#deploy-a-directory) |

[Contents](README.md)

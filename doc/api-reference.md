# anemos v0.1.0 - API Reference

## Modules

- [Anemos](Anemos.md): Anemos — event-driven automation DSL.
- [Anemos.AST](Anemos.AST.md): AST node structs for the Anemos DSL.
- [Anemos.AST.At](Anemos.AST.At.md): A time-triggered `at` block with a time spec, optional guard, and body.
- [Anemos.AST.BinaryOp](Anemos.AST.BinaryOp.md): A binary operator expression.
- [Anemos.AST.BlockArgs](Anemos.AST.BlockArgs.md): A block argument list of key-value pairs.
- [Anemos.AST.BuiltinCall](Anemos.AST.BuiltinCall.md): A built-in function call (filter, map, reduce, emit).
- [Anemos.AST.Capability](Anemos.AST.Capability.md): A named capability declaration with context, body, and source line.
- [Anemos.AST.Command](Anemos.AST.Command.md): A module command expression with a verb and arguments.
- [Anemos.AST.Condition](Anemos.AST.Condition.md): A named condition declaration with a body and source line.
- [Anemos.AST.Context](Anemos.AST.Context.md): A context scope block with a dotted path and body.
- [Anemos.AST.DataDecl](Anemos.AST.DataDecl.md): A named data declaration with content, optional source/transclude, scope, and source line.
- [Anemos.AST.Demand](Anemos.AST.Demand.md): A `demand` expression referencing a capability with a PAM-style control flag.
- [Anemos.AST.Done](Anemos.AST.Done.md): A `done` statement: exits the current handler with no value.
- [Anemos.AST.Emit](Anemos.AST.Emit.md): An `emit` expression that produces a typed value to an optional destination.
- [Anemos.AST.Flow](Anemos.AST.Flow.md): A named flow declaration with a body and source line.
- [Anemos.AST.For](Anemos.AST.For.md): A `for` loop: iterates `var` over `iterable`, executing body each time. Covers `for`, `each`, `every`, `foreach`.
- [Anemos.AST.If](Anemos.AST.If.md): A conditional `if` block with an optional guard, body, and else branch.
- [Anemos.AST.Introspect](Anemos.AST.Introspect.md): An introspection statement — `show`, `list`, `graph`, `trace`,
`explain`, `exists`, `infer`, `assert` — or `exists` in expression
position. The subject is a bare `{:name, "NAME"}`, a `{:catalogue,
:rules | :conditions | :modules | :events | :policies | :schedules}`, or
`{:expr, expression}`.

- [Anemos.AST.It](Anemos.AST.It.md): An `it` modal reference block.
- [Anemos.AST.Let](Anemos.AST.Let.md): A `let` variable binding.
- [Anemos.AST.ListLiteral](Anemos.AST.ListLiteral.md): A list literal expression.
- [Anemos.AST.Literal](Anemos.AST.Literal.md): A literal value node (string, integer, float, boolean, atom).
- [Anemos.AST.Log](Anemos.AST.Log.md): A `log` expression.
- [Anemos.AST.NextEvent](Anemos.AST.NextEvent.md): A `nextevent` statement: transitions to another `when` block within the
same rule, optionally carrying a `with { }` argument block (A-55).

- [Anemos.AST.NextRule](Anemos.AST.NextRule.md): A `nextrule` statement: dispatches to a different rule's pipeline,
optionally carrying a `with { }` argument block.

- [Anemos.AST.On](Anemos.AST.On.md): An `on <interaction>` block. An interaction is an occurrence, not a
report: it has no truth, is never remembered, and admits `unless` but
not `for`, `until` or a compound form. See `Anemos.Runtime.Interaction`.

- [Anemos.AST.Program](Anemos.AST.Program.md): Top-level program node wrapping all parsed declarations.
- [Anemos.AST.QueryDecl](Anemos.AST.QueryDecl.md): A named query declaration with expect/engine/body/return, scope, and source line.
- [Anemos.AST.Return](Anemos.AST.Return.md): A `return` statement: exits the current handler, optionally with a value.
- [Anemos.AST.Rule](Anemos.AST.Rule.md): A named rule declaration with a body, optional metadata, and source line.
- [Anemos.AST.Set](Anemos.AST.Set.md): A `set` variable assignment.
- [Anemos.AST.SignedBy](Anemos.AST.SignedBy.md): A source-level `signed_by` declaration (A-60).
- [Anemos.AST.Triple](Anemos.AST.Triple.md): An RDF-style triple with subject, predicate, and object.
- [Anemos.AST.UnaryOp](Anemos.AST.UnaryOp.md): A unary operator expression.
- [Anemos.AST.VarRef](Anemos.AST.VarRef.md): A variable reference with an optional sigil prefix.
- [Anemos.AST.When](Anemos.AST.When.md): A `when` trigger block: fires on an event, with optional duration, guard, and body.
- [Anemos.AST.While](Anemos.AST.While.md): A `while` loop: repeats body while condition is truthy.
- [Anemos.Application](Anemos.Application.md): OTP application callback for Anemos. Starts no interpreter.
- [Anemos.Channel](Anemos.Channel.md): Behaviour for channel connectors — the bridge between Anemos emit
operations and the host app's messaging infrastructure.
- [Anemos.Channel.ComnBus](Anemos.Channel.ComnBus.md): Channel connector that publishes envelopes via `Comn.EventBus`.
- [Anemos.Channel.Logger](Anemos.Channel.Logger.md): Default channel connector that logs emitted messages via `Logger.info/1`.
- [Anemos.CompilationResult](Anemos.CompilationResult.md): Result of compiling an Anemos program.
- [Anemos.CompiledCapability](Anemos.CompiledCapability.md): A compiled capability: name, context scope, and handler closure for on-demand execution.

- [Anemos.CompiledCondition](Anemos.CompiledCondition.md): A compiled condition: name, trigger subscriptions, evaluator function, and side effects.

- [Anemos.CompiledData](Anemos.CompiledData.md): A compiled data block.
- [Anemos.CompiledQuery](Anemos.CompiledQuery.md): A compiled query block.
- [Anemos.CompiledRule](Anemos.CompiledRule.md): A compiled rule: name, event subscriptions, handler closure, and optional dwell duration.
- [Anemos.CompiledSchedule](Anemos.CompiledSchedule.md): A compiled schedule: event name, time spec, recurrence, and handler.
- [Anemos.Compiler](Anemos.Compiler.md): Walks the AST produced by `Anemos.Parser` and produces `%Anemos.CompiledRule{}`,
`%Anemos.CompiledCondition{}`, and `%Anemos.CompiledCapability{}` structs with
executable closures. No code generation, no Module.create.
- [Anemos.DataModel](Anemos.DataModel.md): Behaviour for pluggable data format and query engine handlers.
- [Anemos.Envelope](Anemos.Envelope.md): Message envelope for emitted values.
- [Anemos.Event](Anemos.Event.md): Protocol for types that can be dispatched as Anemos events.
- [Anemos.Lexer](Anemos.Lexer.md): NimbleParsec-based tokenizer for the Anemos DSL.
- [Anemos.Module](Anemos.Module.md): Macro for defining Anemos modules — named sets of verb handlers.
- [Anemos.Parser](Anemos.Parser.md): Recursive descent parser for the Anemos DSL.
- [Anemos.Redact](Anemos.Redact.md): Shape summaries for values that must be observable without being disclosed.
- [Anemos.Runtime](Anemos.Runtime.md): Supervisable runtime interpreter for Anemos policies.
- [Anemos.Runtime.ArgSchema](Anemos.Runtime.ArgSchema.md): Validates the arguments of a `[MODULE::verb ...]` command before they
reach a host module.
- [Anemos.Runtime.Builtins](Anemos.Runtime.Builtins.md): Built-in collection-processing functions for pipeline expressions.
- [Anemos.Runtime.CapabilityServer](Anemos.Runtime.CapabilityServer.md): GenServer for a single named capability.
Passive until demanded. Executes its `on demand` handler and returns the result.
- [Anemos.Runtime.ConditionServer](Anemos.Runtime.ConditionServer.md): GenServer for a single named condition.
Holds boolean state. Evaluates incoming events against trigger logic.
Broadcasts `CONDITION_<name>` on false->true transition.
Queryable for current state at any time.
- [Anemos.Runtime.ContextScope](Anemos.Runtime.ContextScope.md): The one comparison that decides whether one context path lies inside another.
- [Anemos.Runtime.ContextStore](Anemos.Runtime.ContextStore.md): Agent holding external key-value context data.
Keys are dotted paths (e.g., "infra.networking.dns.fqdn").
Resolution joins the context path with the variable name to form the lookup key.

- [Anemos.Runtime.DataModelRegistry](Anemos.Runtime.DataModelRegistry.md): Agent mapping data model keyword strings to handler modules.
- [Anemos.Runtime.DataStore](Anemos.Runtime.DataStore.md): GenServer holding named datasets for data blocks.
- [Anemos.Runtime.Demand](Anemos.Runtime.Demand.md): Evaluates a stack of demand operations against capability servers
using PAM-style control flag semantics.
- [Anemos.Runtime.Dispatcher](Anemos.Runtime.Dispatcher.md): GenServer holding compiled rules indexed by subscription.
- [Anemos.Runtime.Duration](Anemos.Runtime.Duration.md): Converts duration tuples (e.g., `{5, :min}`) to milliseconds.
- [Anemos.Runtime.Errors](Anemos.Runtime.Errors.md): Compile-time error code registry for the Anemos runtime.
- [Anemos.Runtime.Interaction](Anemos.Runtime.Interaction.md): The vocabulary shared by `on <interaction>` blocks and the host.
- [Anemos.Runtime.Introspection](Anemos.Runtime.Introspection.md): Answers the introspection statements — `show`, `list`, `graph`, `trace`,
`explain`, `exists`, `infer` — from the dispatcher's state.
- [Anemos.Runtime.LoadAuthority](Anemos.Runtime.LoadAuthority.md): The trust boundary on loading policy (A-12).
- [Anemos.Runtime.LoadAuthority.Denied](Anemos.Runtime.LoadAuthority.Denied.md): Refuses every load.
- [Anemos.Runtime.LoadAuthority.Permissive](Anemos.Runtime.LoadAuthority.Permissive.md): The default authority: grants every load.
- [Anemos.Runtime.LoadAuthority.Signed](Anemos.Runtime.LoadAuthority.Signed.md): A load authority that verifies detached Ed25519 signatures over the
policy source (A-05).
- [Anemos.Runtime.LoadRequest](Anemos.Runtime.LoadRequest.md): Everything an `Anemos.Runtime.LoadAuthority` gets to decide on.
- [Anemos.Runtime.Module](Anemos.Runtime.Module.md): Behaviour for Anemos runtime modules (DEVICE, FILE, etc.).
- [Anemos.Runtime.ModuleRegistry](Anemos.Runtime.ModuleRegistry.md): Maps module names (e.g. "DEVICE", "FILE") to Elixir modules
implementing the `Anemos.Runtime.Module` behaviour.
- [Anemos.Runtime.Modules.Device](Anemos.Runtime.Modules.Device.md): Stub DEVICE module for development and testing.
- [Anemos.Runtime.Modules.Example](Anemos.Runtime.Modules.Example.md): Demonstration doubles for the module verbs used by `priv/examples/`.
- [Anemos.Runtime.Modules.Example.Event](Anemos.Runtime.Modules.Example.Event.md): `EVENT` double. Verb names are dotted event names (`ip.addr.changed`),
so `handle_verb/3` accepts any verb and echoes it rather than
enumerating a fixed list.

- [Anemos.Runtime.Modules.Example.File](Anemos.Runtime.Modules.Example.File.md): `FILE` double that answers `extension` from the path under evaluation.
- [Anemos.Runtime.Modules.Example.Infra](Anemos.Runtime.Modules.Example.Infra.md): `INFRA` double for `ddns.rule`.
- [Anemos.Runtime.Modules.Example.Pdf](Anemos.Runtime.Modules.Example.Pdf.md): `PDF` double distinguishing document content from stored metadata.
- [Anemos.Runtime.Modules.Example.Secret](Anemos.Runtime.Modules.Example.Secret.md): `SECRET` double that deliberately yields nothing usable.
- [Anemos.Runtime.Modules.Example.String](Anemos.Runtime.Modules.Example.String.md): `STRING` double. `slugify` is a genuine pure function, not a stand-in —
there is nothing to fake about lowercasing and hyphenating a string.

- [Anemos.Runtime.Modules.File](Anemos.Runtime.Modules.File.md): Stub FILE module for development and testing.
- [Anemos.Runtime.Modules.Policy](Anemos.Runtime.Modules.Policy.md): `[POLICY::unload "id"]` — a policy that removes another.
- [Anemos.Runtime.NLD](Anemos.Runtime.NLD.md): Natural Language Date resolver.
- [Anemos.Runtime.PathGuard](Anemos.Runtime.PathGuard.md): Confines a caller-supplied path to a configured root.
- [Anemos.Runtime.PolicyStore](Anemos.Runtime.PolicyStore.md): Durable record of everything that has been loaded into a runtime.
- [Anemos.Runtime.Report](Anemos.Runtime.Report.md): What an event *reports*, and what a compound trigger makes of the reports
it has heard (A-47).
- [Anemos.Runtime.RuleSupervisor](Anemos.Runtime.RuleSupervisor.md): Second supervision tier: rule-scoped processes.
- [Anemos.Runtime.Scheduler](Anemos.Runtime.Scheduler.md): GenServer that manages time-triggered schedules.
- [Anemos.Runtime.Standalone](Anemos.Runtime.Standalone.md): Wires a dispatcher and its stores together outside a full `Anemos.Runtime`
tree.
- [Anemos.Runtime.StateTable](Anemos.Runtime.StateTable.md): Where a runtime keeps what its processes have accumulated, so that the
restart of one of them does not lose it.
- [Anemos.Runtime.StoreSupervisor](Anemos.Runtime.StoreSupervisor.md): Supervisor for stores-as-infrastructure.
- [Anemos.Runtime.SubscribableRegistry](Anemos.Runtime.SubscribableRegistry.md): Agent mapping protocol strings to `Anemos.Subscribable` handler modules.
- [Anemos.Runtime.TripleStore](Anemos.Runtime.TripleStore.md): Agent-based triple store for RDF-like facts.
- [Anemos.Runtime.TrustStore](Anemos.Runtime.TrustStore.md): Per-runtime trust configuration: a keyring of **public** verification
keys, and the policy for sources that declare no signer at all (A-05).
- [Anemos.Runtime.Watcher](Anemos.Runtime.Watcher.md): Keeps a directory of `*.rule` files deployed into a runtime.
- [Anemos.Secret](Anemos.Secret.md): A wrapper for secret-bearing values that refuses to disclose itself.
- [Anemos.Subscribable](Anemos.Subscribable.md): Behaviour for data sources that support dynamic subscription.

## Mix Tasks

- [mix anemos.run](Mix.Tasks.Anemos.Run.md): Parse and execute a `.rule` file against a given event.


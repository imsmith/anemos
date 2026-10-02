# Hot reload: deploying a policy over itself

**Date:** 2026-10-02 · **Branch:** `hot-reload` · **Status:** driven, rulings ledgered below

## Problem

The PRD requires it: "Rules are hot-reloadable: file changes trigger
recompilation and re-registration without system restart." The runtime does
not do it.

What exists is `Anemos.Runtime.load/3`, which accumulates. Loading an edited
source replaces the rules whose names it repeats, and nothing else:

- a rule deleted from the source keeps running;
- a condition or capability deleted from the source keeps its server;
- a global `data` block deleted from the source stays registered, and a live
  subscription behind one is never cancelled;
- an `at` block deleted from the source keeps its timer;
- every replaced rule loses its `set` bindings and armed dwell timers, and
  every replaced condition reads `false`, whether or not its text changed;
- nothing watches a file.

The root cause is stated in the dispatcher's own documentation: "a
policy-level unload would need a policy identity, which
`Anemos.CompilationResult` does not carry."

## Principle

A policy is immutable. It is never edited in place; a new one is deployed
over the current one. Deployment is therefore the only operation, and it has
to be exact: after deploying version N+1 of a policy, the runtime holds what
N+1 declares and nothing N declared that N+1 does not.

## Design

### §1 — Policy identity

`load/3` takes a `:policy` option, a non-empty string chosen by the caller (a
path, a name, a tenant-qualified key).

```elixir
Anemos.Runtime.load(:anemos, source, policy: "garage/lights.rule")
```

A load with an identity **deploys**: it replaces whatever was last loaded
under that identity. A load without one behaves exactly as today
(accumulate, replace rules by name) — no existing caller changes behaviour.

Two more functions on `Anemos.Runtime`:

- `unload(name, policy_id)` — removes everything the policy declared.
  `:ok | {:error, :not_loaded}`.
- `policies(name)` — the loaded policies in load order, each
  `%{id, rules, conditions, capabilities, schedules, data_blocks}` with the
  declaration names. Anonymous loads appear with `id: nil`.

The gate is unchanged: a deploy goes through `LoadAuthority.gate/3` like any
load. A source that fails the gate, the parser or the compiler changes
nothing — the previous version keeps running.

### §2 — What a deploy does

Given the previous version `old` and the new version `new` of one policy:

| Declaration | In `old`, not in `new` | In both, text unchanged | In both, text changed | Only in `new` |
| --- | --- | --- | --- | --- |
| rule | removed, with its `set` bindings, dwell timers and rule-scoped data | definition swapped, **state kept** | replaced, state reset | added |
| condition | server stopped | **server and state kept** | server replaced, reads `false` | started |
| capability | server stopped | replaced (stateless) | replaced | started |
| global `data` block | deregistered, subscription cancelled | re-registered | re-registered | registered |
| schedule (`at`) | disarmed, unless another loaded policy declares the same time | timer left running | n/a (the name is the time) | armed |

"Text unchanged" means the declaration's AST is equal once source positions
are removed. Moving a rule down the file, or editing its neighbour, does not
reset it. This is computed per top-level declaration by fingerprinting the
AST; the compiler already compiles declarations independently.

The deploy is one dispatcher call, so no event is dispatched against a
half-replaced policy.

### §3 — Name conflicts between policies

Rule, condition and capability names are global in a runtime. A deploy that
declares a name owned by a *different identified* policy is refused with
`{:error, message}` naming both policies, and nothing is loaded. Silent
cross-policy replacement was A-61's failure and is A-64's open complaint; with
identities it can be refused instead of logged.

Anonymous loads keep last-writer-wins, as today.

### §4 — Watching a directory

`Anemos.Runtime.Watcher` keeps a directory of `*.rule` files deployed into a
runtime. Policy identity is the path relative to the directory.

```elixir
{Anemos.Runtime, name: :anemos, watch: "/etc/anemos/policies"}
```

- new or changed file: deployed;
- deleted file: unloaded;
- a file that fails to load: the previous version keeps running, the failure
  is logged once per distinct content and held for `Watcher.status/1`;
- `<file>.sig`, if present, is passed as the detached signature, and a
  change to it counts as a change to the file.

`Watcher.status/1` answers `%{policy_id => :ok | {:partial, failures} | {:error, reason}}`.
`Watcher.scan/1` runs one pass synchronously.

Change detection is a content hash on a poll (default one second). No new
dependency, and no reliance on mtime granularity. The ceiling is reading
every policy file each interval; an inotify source belongs to the substrate
(the llmagent event work), not here.

## Rulings

1. **Identity is opt-in.** Making every load identified would change the
   meaning of existing calls.
2. **State survives an unchanged declaration, and only that.** A changed rule
   body did not produce the old bindings; the existing reasoning in
   `merge_rules/2` stands for changed text.
3. **Conflicts are refused only between identified policies.**
4. **A redeployed policy moves to the end of the load order**, matching what
   the live rule list already does on replacement.
5. **Polling, not inotify.**
6. **Schedules already armed are not re-armed on deploy**, so an interval's
   phase survives a reload. Anonymous loads re-arm, as today.

## Not in this spec

- State surviving a *process restart* (A-40 to A-43, and the scheduler
  losing its timers when the dispatcher restarts). Next spec.
- Introspection verbs (`show`, `list`, `trace`, `explain`). The spec after.
  `policies/1` and `Watcher.status/1` are the minimum this one needs.
- A live subscription behind a `data` block is not re-established after a
  dispatcher restart without duplicating it. Pre-existing; filed, not fixed.

## Testing

Each row and column of the §2 table is a test through `Anemos.Runtime`.
Conflict refusal, failed-deploy-changes-nothing, `unload/2`, `policies/1`.
The watcher is tested against a real temporary directory with `scan/1`:
add, edit, break, fix, delete, signature sidecar.

# Issues

Tracked here until they migrate to a real issue tracker. Newest first.

## `Anemos.Runtime.RuleSupervisor` is dead code that ships in the published docs

**Filed:** 2026-08-04
**Reported from:** as-built architecture review

### Symptom

`Anemos.Runtime.RuleSupervisor` is referenced by exactly one line in the whole
tree — its own `defmodule`:

```text
$ grep -rn "RuleSupervisor" --include=*.ex --include=*.exs lib test
lib/anemos/runtime/rule_supervisor.ex:1:defmodule Anemos.Runtime.RuleSupervisor do
```

It is not in the `Anemos.Runtime` supervisor's child list
(`lib/anemos/runtime.ex:169-181` starts `ModuleRegistry`, `ContextStore`,
`Dispatcher`, `Scheduler` — nothing else), and `Anemos.Application` starts no
children at all. Nothing calls `RuleSupervisor.start_link/1`.

The module's own moduledoc admits its status
(`lib/anemos/runtime/rule_supervisor.ex:2-7`):

```text
Minimal structure for v0.1.0 — ready to supervise per-rule
GenServers when stateful rule execution is needed.
```

Despite that, `doc/` ships it as a live API page:

```text
$ ls doc/ | grep RuleSupervisor
Anemos.Runtime.RuleSupervisor.html
Anemos.Runtime.RuleSupervisor.md
```

A reader of the generated documentation has no way to tell this supervisor from
the ones the runtime actually starts.

### Why it happens

ExDoc documents every public module it finds. Placeholder modules written ahead
of the feature that will use them are indistinguishable, in the output, from
load-bearing ones.

### What should change

Decide whether per-rule supervision is still on the roadmap. If it is, mark the
module `@moduledoc false` (or exclude it from the ExDoc groups) until it is
wired into `Anemos.Runtime.init/1`. If it is not, delete it. Either way the
published docs should stop advertising an unstarted supervisor.

---

## `Anemos.Runtime.DataModelRegistry` is exercised only by its own tests

**Filed:** 2026-08-04
**Reported from:** as-built architecture review

### Symptom

Outside its own definition, `DataModelRegistry` appears only in a test file and
in one unrelated moduledoc:

```text
$ grep -rn "DataModelRegistry" --include=*.ex --include=*.exs lib test
lib/anemos/runtime/data_model_registry.ex:...   (definition + doctests)
lib/anemos/runtime/subscribable_registry.ex:5:  Unlike `DataModelRegistry` (which derives the key from the handler via
test/anemos/data_model_test.exs:5,17,18,19,24,25,26
```

No process starts it. `Anemos.Runtime.init/1` (`lib/anemos/runtime.ex:169-181`)
does not list it among its children, and `Anemos.Runtime.Dispatcher.init/1`
starts `TripleStore`, `DataStore` and `SubscribableRegistry`
(`lib/anemos/runtime/dispatcher.ex:125-129`) but never `DataModelRegistry`.

The result: the `Anemos.DataModel` behaviour has a registry that no running
system consults. Format-keyword lookup exists as a tested function and as
nothing else.

### Why it happens

`SubscribableRegistry` was added later with an overlapping job — the comment at
`lib/anemos/runtime/subscribable_registry.ex:5` contrasts the two — and the
dispatcher was wired to the newer one. The older registry was left in place.

### What should change

Decide which of the two registries the runtime is supposed to use. If
`DataModelRegistry` is the intended home for format-keyword dispatch, add it to
the supervision tree and have the dispatcher consult it. If `SubscribableRegistry`
superseded it, remove `DataModelRegistry` and its tests rather than leaving two
registries with one live consumer between them.

---

## `Anemos.Application` starts no supervision tree

**Filed:** 2026-08-04
**Reported from:** as-built architecture review

### Symptom

`lib/anemos/application.ex:15` declares an empty child list:

```elixir
def start(_type, _args) do
  # Re-discover Comn registries now that Anemos modules are loaded
  Code.ensure_loaded!(Anemos.Runtime.Errors)
  Comn.Errors.Registry.discover()
  Comn.Discovery.discover()

  children = []

  opts = [strategy: :one_for_one, name: Anemos.Supervisor]
  Supervisor.start_link(children, opts)
end
```

The application callback's entire effect is the two `discover/0` calls. The
supervisor it starts has nothing to supervise; `Anemos.Supervisor` exists as a
named process with zero children.

This is not by itself a bug — Anemos is a library whose runtime is started by
its host — but it means the OTP application boundary carries no information
about what the system runs. Every claim about "the supervision tree" has to be
read out of `Anemos.Runtime`, which callers start themselves.

### What should change

Either document in the moduledoc (currently `@moduledoc false`) that this is a
library application whose supervision tree is host-started via
`Anemos.Runtime.start_link/1`, or fold the discovery calls into a proper child
and drop the empty supervisor. The current shape gives a reader no signal
either way.

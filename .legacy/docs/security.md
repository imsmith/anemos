# Anemos — Security Analysis

**Date:** 2026-08-06
**Scope:** `/home/imsmith/github/anemos` @ `80ba1b4` (branch `main`), plus the path
dependency `../comn` where Anemos calls into it.
**Method:** full read of `lib/` (39 files, ~6,455 LOC), `mix.exs`, `mix.lock`,
`config/`, `priv/examples/`, and targeted read of `comn` at every call site Anemos
reaches.

---

## 0. What this system actually is

Anemos is an event-driven automation DSL implemented as an Elixir library. It has:

- a NimbleParsec lexer and a hand-written recursive-descent parser,
- a compiler that turns the AST into **executable closures** (not generated modules),
- an OTP runtime — dispatcher, condition servers, capability servers, scheduler,
  registries, triple store, data store,
- a `Mix` task (`mix anemos.run`) and a library API (`Anemos.Runtime.load/2`).

**There is no web layer.** No Phoenix, no Plug, no Cowboy, no controllers, no routes,
no session store, no cookies, no WebSocket endpoint. `cowlib` appears in `mix.lock`
only as a transitive dependency of `gnat` (NATS), pulled through `comn`.

That means audit sections 1, 2, 3, 5, and 9 (authentication, HTTP authorization,
CORS, WebSocket, OAuth/webhooks) have **no implementation to review**. That is not a
clean bill of health — it is the finding. Anemos is a policy engine that executes
privileged operations, and it was built with no trust boundary of any kind. The
security model is entirely deferred to a host application that does not exist yet,
while the DSL itself advertises security controls (`signed_by`, `context`,
`capability`/`demand`) that are parsed and then ignored.

Read the report with that framing: the danger here is not a missing `httpOnly` flag.
It is that the whole thing is a confused-deputy engine wired directly to secrets and
infrastructure verbs.

---

## 1. Severity summary

| Severity | Count | Findings |
| --- | --- | --- |
| CRITICAL | 2 | C-1, C-2 |
| HIGH | 6 | H-1 … H-6 |
| MEDIUM | 8 | M-1 … M-8 |
| LOW | 4 | L-1 … L-4 |
| INFORMATIONAL | 5 | I-1 … I-5 |

---

## 2. CRITICAL

### C-1 — Policy source is loaded and executed with zero trust boundary

`lib/anemos/runtime.ex:56` — `Anemos.Runtime.load/2` accepts an arbitrary source
string at runtime, parses it, compiles it to closures, and installs it into the live
dispatcher. There is no caller authentication, no authorization check, no signature
verification, no sandbox, and no resource ceiling.

```elixir
def load(name, source) do
  with {:ok, ast} <- Anemos.Parser.parse(source),
       {:ok, compiled} <- Anemos.Compiler.compile(ast) do
    Dispatcher.load(dispatcher_name(name), compiled)
```

The compiled closures then execute inside the dispatcher's own process
(`lib/anemos/runtime/dispatcher.ex:231`, `safe_handle/4`), with the full privileges
of the BEAM node. `Anemos.Runtime` is also exposed through the `Comn` behaviour —
`act(%{action: :load, name: name, source: source})` at `lib/anemos/runtime.ex:208` —
which means anything that can reach the generic Comn action dispatcher can load
policy.

The documented design (`CLAUDE.md`, and the module docs at `lib/anemos/runtime.ex:8-25`)
is explicitly "blank interpreter, everything loads dynamically, no startup config."
That is a reasonable architecture, but it makes *policy text the privilege boundary*,
and there is currently no boundary at all. Whoever controls a `.rule` string controls
every module verb registered in the runtime — including, per the shipped example, the
one that unlocks DDNS credentials.

**Impact:** full compromise of whatever the host has registered. Arbitrary
infrastructure actions, secret exfiltration, and node-level denial of service.

**Fix:** treat `load/2` as a privileged operation. Require a verified signature
(see H-1) or restrict it to a supervised bootstrap path that reads from a
root-owned directory. Do not expose it via `Comn.act/1`.

---

### C-2 — No input validation exists between DSL/event data and host module verbs

`lib/anemos/runtime/dispatcher.ex:490-497`:

```elixir
defp execute_op(%{type: :command, module: mod_name, verb: verb, args: args}, context, state) do
  case ModuleRegistry.lookup(state.registry, mod_name) do
    {:ok, mod} -> mod.handle_verb(verb, args, context)
```

`args` arrives from two sources — literals in the policy text and values resolved from
the event payload / `ContextStore` — and is passed **verbatim** to host code. There is
no argument schema, no type check, no length bound, no allow-list, no escaping, and no
taint tracking anywhere in the pipeline. The `Anemos.Module` macro
(`lib/anemos/module.ex:56-67`) makes it a one-liner to bind a DSL verb directly to a
powerful host function, and its own moduledoc uses secret unlocking as the worked
example:

```elixir
verb :unlock, &Comn.Secret.unlock/2
verb :rotate, &Comn.Secret.rotate/1
```

This is the injection surface for the entire system, and it is unguarded by
construction. Concretely, in the substrate Anemos already depends on:

- `Comn.Repo.File.Local` (`../comn/lib/comn/repo/file/local.ex:29, 75, 86, 110`) calls
  `File.open/2`, `File.stream!/1`, and `File.write` on a caller-supplied path with **no
  normalization and no root confinement**. Wire it to a `FILE` verb — which
  `lib/anemos/runtime/modules/file.ex` exists as a placeholder for, its own docs saying
  "Replace with a real implementation for production use" — and `[FILE::read "../../etc/shadow"]`
  is a working path traversal on day one.
- `Comn.Repo.Cmd.Shell` is declared and discovered but returns `:not_implemented`. When
  it is implemented, the same unguarded path becomes command execution.

**Impact:** arbitrary file read/write/delete and (once `Cmd.Shell` lands) command
execution, reachable from policy text and from event payloads.

**Fix:** introduce a validation layer in the framework, not in each host module.
Give `Anemos.Runtime.Module` an optional `arg_schema/1` callback the dispatcher
enforces before `handle_verb/3`. Separately, confine every path-taking verb to a
configured root via `Path.expand/2` plus a prefix assertion.

---

## 3. HIGH

### H-1 — `signed_by` is parsed and never verified; `Envelope.signature` is never populated

`lib/anemos/parser.ex:163`:

```elixir
defp parse_rule_metadata([{:keyword, _, :signed_by}, {:atom, _, signer} | rest], acc) do
  parse_rule_metadata(rest, Map.put(acc, :signed_by, signer))
end
```

The signer is stored in rule metadata and never read again. Grep confirms zero
verification code: no crypto call, no key lookup, no comparison — anywhere in `lib/`.
Likewise `Anemos.Envelope` (`lib/anemos/envelope.ex:18`) declares a `:signature`
field, and the dispatcher constructs envelopes at `dispatcher.ex:279-286` without
ever setting it. `README.md:458` describes the field as "Reserved for cryptographic
signing"; `docs/design-notes/future-features.md:141` places DID signing in the
*future* section.

This is worse than having no signing at all. A rule file that reads `signed_by
:operator.did` looks authenticated to every human and every tool that inspects it,
and is accepted identically to an unsigned one. It manufactures false provenance.

**Fix:** either implement verification before `load/2` installs the rule, or remove
the keyword from the lexer and the field from the envelope until it is real. Do not
ship a parsed-but-ignored security attribute.

---

### H-2 — Context isolation fails open

Context is the DSL's declared exclusionary boundary — a rule scoped to
`infra.networking.dns` is supposed to be unreachable from events outside that scope.
The enforcement is `lib/anemos/runtime/dispatcher.ex:443-450`:

```elixir
defp context_matches?(_rule, nil), do: true

defp context_matches?(rule, event_context) do
  case get_in(rule, [Access.key(:meta), :context_path]) do
    nil -> true
    rule_context -> String.starts_with?(event_context, rule_context)
  end
end
```

Two defects, either of which voids the boundary:

1. **An event with no `:context_path` matches every rule, regardless of scope.**
   `Anemos.Runtime.dispatch(:anemos, "EVENT")` omits context by default
   (`runtime.ex:132`), so the *default* dispatch path bypasses context entirely. Any
   caller that can emit an unscoped event reaches every rule in the runtime.
2. **The prefix match is unanchored.** `String.starts_with?/2` has no dot-boundary
   check, so a rule scoped to `infra.net` matches an event in `infra.network.public`
   and in `infra.netfoo.anything`. Scope confusion via sibling-name prefixes.

**Fix:** default-deny on missing context (`context_matches?(_rule, nil), do: false`
for any rule that declares a context), and compare on segment lists rather than raw
string prefixes.

---

### H-3 — Capability context scoping is decorative; any rule can demand any capability

`Anemos.Runtime.CapabilityServer` takes a `:context` at init and stores it
(`lib/anemos/runtime/capability_server.ex:124`) — and never reads it again.
`handle_call({:execute, context}, ...)` at line 131 invokes the handler
unconditionally. `Anemos.Runtime.Demand.evaluate/3`
(`lib/anemos/runtime/demand.ex:44-53`) looks the capability up by name in a flat map
and executes it, with no comparison against the demanding rule's context.

So the `context infra.networking` line in the shipped example
(`priv/examples/ddns.rule:2-9`) constrains nothing. A rule declared in any context —
or in none — can `demand katachora-ddns-key` and receive the unlocked secret.

Combined with H-2, there is no working scope isolation anywhere in the runtime.

**Fix:** pass the demanding rule's context into `CapabilityServer.execute/2` and
reject on mismatch inside the server, where the capability's own context lives.

---

### H-4 — Unbounded atom creation from policy text crashes the whole node

Every distinct identifier in a policy source becomes a permanent VM atom. Atoms are
never garbage collected, and exceeding the table limit (default 1,048,576) is an
unrecoverable `system_limit` abort of the **entire BEAM node** — not a supervised
process crash.

Call sites, all reached from untrusted source text:

- `lib/anemos/lexer.ex:504` — `String.to_atom(value)` on **every identifier token**
- `lib/anemos/lexer.ex:432` — duration units
- `lib/anemos/lexer.ex:472` — `DAY_*` literals
- `lib/anemos/lexer.ex:499` — demand flags
- `lib/anemos/parser.ex:484` — recurrence names
- `lib/anemos/parser.ex:1529` — `expect` atom lists

`lexer.ex:504` is the serious one: it converts first and checks membership second, so
non-keyword identifiers are interned as a side effect of the keyword test.

Because `load/2` is designed to be called repeatedly at runtime (C-1), a single
attacker-supplied policy containing ~1M unique identifiers — or a loop of small
ones — takes the node down permanently. Compare: policy *parse* failure is
recoverable; atom exhaustion is not.

**Fix:** at `lexer.ex:504`, use a compile-time `MapSet` of keyword/operator **strings**
and never convert unmatched identifiers. Use `String.to_existing_atom/1` with a
rescue at the other five sites, where the accepted values are closed sets.

---

### H-5 — The default channel connector logs full payloads, and the canonical example routes secrets through it

`lib/anemos/channel/logger.ex:52`:

```elixir
Logger.info("[anemos]#{type} emit to #{channel}#{label}: #{inspect(envelope.payload)}")
```

This is the **default** connector — `lib/anemos/channel.ex:26-28` states plainly that
it is used when nothing is registered, "so emits are never silent." The `log`
operation does the same at `dispatcher.ex:499-503`.

Now read the shipped example, `priv/examples/ddns.rule:5-8`:

```
on demand {
  emit [SECRET::unlock(agent.did_meshid_z6MkAgent123.operator.security:did_key_67890)]
    as :katachora.ddns.key
}
```

The documented, exemplary way to obtain a secret is to `emit` it. With the default
connector, the unlocked secret is `inspect`ed into the application log at `:info`
level — and from there into whatever ships logs off the host. No redaction exists
anywhere in the codebase; there is no `Inspect` protocol override, no `:redact`
marking, no sensitive-value wrapper type.

**Impact:** plaintext credential disclosure to logs in the default configuration,
following the project's own example.

**Fix:** introduce a wrapper struct for secret-bearing values with a custom `Inspect`
implementation that renders `#Secret<redacted>`, and have `SECRET`-class verbs return
it. Change `Channel.Logger` to log payload *type and size*, never contents.

---

### H-6 — `ModuleRegistry` is an unprotected `Agent`; verb routing can be silently hijacked

`lib/anemos/runtime/module_registry.ex:27-29`:

```elixir
def register(registry, name, module) do
  Agent.update(registry, &Map.put(&1, name, module))
end
```

Last write wins, with no authorization, no immutability, and no duplicate detection.
Any process in the VM that can name the registry (`:"#{name}.registry"` — derived
from a public, documented convention at `runtime.ex:214`) can rebind `"SECRET"` or
`"INFRA"` to an attacker-chosen module. Every subsequent `[SECRET::unlock ...]`
dispatches to it, with the arguments intact, and the policy behaves normally from the
outside.

`SubscribableRegistry` (`subscribable_registry.ex:58`) and `ContextStore`
(`context_store.ex:170`) have the same shape: unprotected global mutable state
addressable by a guessable name. `ContextStore` additionally holds the values that
`?variable` dereferences resolve to, so writing it lets an attacker steer rule logic.

This requires in-VM code execution to exploit, which is why it is HIGH rather than
CRITICAL — but on the BEAM, "another application in the same release" is a routine
adversary, and this is the difference between defense in depth and none.

**Fix:** make module registration write-once (reject rebinding a live name, or
require an explicit `replace: true`). At minimum, log every registration and
re-registration at `:warning`.

---

## 4. MEDIUM

### M-1 — The demand stack fails open on unknown capabilities

`lib/anemos/runtime/demand.ex:55-63`:

```elixir
defp handle_missing(demand, rest, registry, context, results, deferred_error) do
  error = {:error, {:unknown_capability, demand.capability}}
  case demand.flag do
    :requisite -> error
    :required  -> eval_stack(rest, ..., deferred_error || error)
    :optional  -> eval_stack(rest, ..., deferred_error)
    :sufficient -> eval_stack(rest, ..., deferred_error)
  end
end
```

A capability that **does not exist** is treated the same as one that merely failed.
Under `:optional` or `:sufficient` the stack continues and, if nothing else fails,
`eval_stack/5` returns `{:ok, results}` — the gate passes having authorized nothing.
A demand stack composed entirely of `:optional` flags is a no-op that reads like an
authorization check.

PAM's flag semantics are about *failure* handling. "The named capability is not
loaded" is a configuration error, not a failure, and should be fatal regardless of
flag. A typo in a capability name currently disables the gate silently.

**Fix:** make `handle_missing/6` return the error unconditionally, independent of flag.

### M-2 — Unbounded timers permit trivial resource exhaustion from policy

`lib/anemos/runtime/scheduler.ex:83-86`:

```elixir
defp start_timer(%{time_spec: {:interval, dur}, event_name: name, recurrence: :interval}) do
  ms = duration_to_ms(dur)
  {:ok, ref} = :timer.send_interval(ms, {:fire, name})
```

`Anemos.Runtime.Duration.to_ms/1` (`duration.ex:21-29`) applies no floor, no ceiling,
and no sanity check. A policy specifying a 1 ms interval installs a 1000 Hz message
loop that calls `Anemos.Runtime.dispatch/2` — a synchronous `GenServer.call` into the
dispatcher — on every tick. A handful of such rules saturates the dispatcher and
starves every other rule in the runtime. There is no limit on the number of schedules
a policy may install, either.

Separately, `to_ms/1` has no catch-all clause: an unrecognized unit raises
`FunctionClauseError` inside the scheduler's `init/1`, taking the scheduler down.

**Fix:** clamp intervals to a configured minimum (1 s is generous), cap total
schedules per runtime, and add a `to_ms/1` fallback returning `{:error, :bad_unit}`.

### M-3 — Internal error detail is returned to callers

`lib/anemos/runtime/dispatcher.ex:467-479` rescues eight exception types and returns
`Exception.message(e)` verbatim; `dispatcher.ex:409-411` wraps it as
`"Rule #{rule.name} raised: #{inspect(reason)}"`. These flow out through
`Anemos.Runtime.dispatch/3` to whatever called it.

`KeyError` and `BadMapError` messages embed the full offending term. In a runtime
whose stated purpose is handling secrets and infrastructure state, a `KeyError` on a
map containing an unlocked credential prints that credential into the error result —
and, via the Mix task at `anemos.run.ex:54`, onto the console.

**Fix:** log the detailed error internally with a correlation id (the dispatcher
already generates one at `dispatcher.ex:354` using `:crypto.strong_rand_bytes/1`),
and return only the id plus a stable error code to the caller.

### M-4 — Unsafe deserialization in the `comn` SQLite queue

`../comn/lib/comn/repo/queue/sqlite.ex:128, 167, 196` call
`:erlang.binary_to_term(payload)` **without the `[:safe]` flag**, on blobs read from a
SQLite file on disk. The same file's own `Comn.Secrets` code gets this right
(`../comn/lib/comn/secrets/local.ex:140` uses `[:safe]`), so this is an oversight, not
a policy.

Anyone who can write the queue file can inject arbitrary terms — including
pids, refs, and funs — and can exhaust the atom table (see H-4) from a data file.

**Fix:** add `[:safe]` at all three call sites. It is a one-word change.

### M-5 — NATS transport defaults to plaintext with no authentication

`../comn/lib/comn/events/nats.ex:47-49` splits out `:host`, `:port`, `:tls`, and
`:ssl_opts`, and defaults to `%{host: "127.0.0.1", port: 4222}` — TLS off. No
credential options are plumbed at all: no user/password, no token, no NKey, no JWT,
despite `nkeys` and `kcl` being present in the lock file as `gnat` dependencies.

If a host wires Anemos's channel output to NATS (a documented intent — `Anemos.Channel`
lists NATS as an example connector at `channel.ex:23`), emitted envelopes — including
the secret-bearing ones from H-5 — cross the network unencrypted and unauthenticated
by default.

**Fix:** default `tls: true`, require explicit opt-out, and plumb NKey/JWT credentials.

### M-6 — Weak key derivation in `Comn.Secrets.Local`

`../comn/lib/comn/secrets/local.ex:33`:

```elixir
# In production, you'd use proper key derivation (HKDF)
# For now, hash the private key to get 32 bytes for ChaCha20
symmetric_key = :crypto.hash(:sha256, key.private)
```

The code documents its own defect. Consequences: the ChaCha20 key is a deterministic
function of the Ed25519 private key with no salt and no context separation, so the
same key material is reused across every purpose and every blob; and using a signing
key for encryption violates key separation outright. There is no rotation path — no
`rotate/1` implementation, no key versioning in `LockedBlob`.

Nonce handling is correct (`:crypto.strong_rand_bytes(12)`, fresh per operation),
though random 96-bit nonces carry a birthday bound that argues for a counter at high
volume.

**Fix:** derive with HKDF-SHA256 using a per-purpose `info` string and a random salt
stored alongside the blob. Use an X25519 key for encryption, not the Ed25519 signing key.

### M-7 — `erl_crash.dump` (5.8 MB) sits in the working tree

A full BEAM heap dump from 2026-04-16 is present at the repo root. It is correctly
`.gitignore`d and not tracked, so it will not reach the remote — but it is a complete
snapshot of process memory on a developer machine, and heap dumps routinely contain
credentials, tokens, and decrypted secrets. A string scan finds test fixture material
(`TestSecret`) rather than live credentials, so no live secret is known to be exposed
here. Delete it anyway; it is a standing liability that grows every time the VM dies
during a run that touched real material.

### M-8 — `mix.lock` is listed in `.gitignore`

`.gitignore:33` ignores `mix.lock`. The file is nonetheless tracked (it predates the
rule and shows as modified in `git status`), so the immediate effect is only that
lockfile changes are easy to miss. The intent is the problem: ignoring the lockfile
for an application means unpinned transitive dependencies and non-reproducible builds
— every `mix deps.get` on a fresh checkout could resolve different versions of
`exqlite`, `req`, and the crypto libraries. It also conflicts directly with the
project's own SPDX/SBOM standard, which requires knowing exactly what shipped.

**Fix:** remove `mix.lock` from `.gitignore` and commit the current lockfile
deliberately. Lockfiles are ignored for *libraries published to Hex*, and even then
only by convention — Anemos declares an application (`mod: {Anemos.Application, []}`).

---

## 5. LOW

### L-1 — Production stub modules are registered by default

`lib/anemos.ex:14-17` registers `Modules.Device` and `Modules.File` for every
`Anemos.run/2` call. Both are echo stubs whose own moduledocs say "Replace with a real
implementation for production use" (`modules/file.ex:6`, `modules/device.ex:6`). They
are inert — they perform no I/O — so the risk is not what they do but what they hide:
a policy referencing `[FILE::write ...]` silently succeeds against a stub, so a
misconfigured deployment looks healthy while doing nothing. Fail loudly instead.

### L-2 — Unbounded growth in `rule_bindings`

The dispatcher accumulates per-rule persistent bindings in state
(`dispatcher.ex:412`, `put_in(st.rule_bindings[rule.name], new_persistent)`) with no
eviction, no size cap, and no TTL. `set` variables and dwell-timer entries persist for
the process lifetime. A policy that accumulates into a `set` variable grows the
dispatcher's heap without bound. Memory pressure, not compromise.

### L-3 — Pure-Elixir cryptography in the dependency chain

`kcl` 1.5.1 (NaCl in pure Elixir) and `nkeys` 0.3.1 are pulled in via `gnat`. Pure
BEAM crypto implementations do not offer the constant-time guarantees of libsodium or
OpenSSL and are, in principle, susceptible to timing side channels. They are currently
only on the NATS authentication path. Note it; do not extend their use to anything
Anemos does directly. `Comn.Secrets.Local` correctly uses `:crypto` (OpenSSL-backed).

### L-4 — Repository hygiene

A stray file named `● Here's where we stand against the spec.md` is untracked at the
repo root — an artifact of a terminal paste, not a document. Two `.tcl` files at root
(`stop-data-extraction-policy.tcl`, `ingress-traffic-policy.tcl`) are marked
executable (`0755`) but are DSL sketches, not scripts; they have no shebang and will
fail confusingly if executed. Remove the stray file and drop the executable bit.

---

## 6. INFORMATIONAL

### I-1 — SQL construction is parameterized

Every query in `../comn/lib/comn/repo/queue/sqlite.ex` uses `Sqlite3.prepare/2` with
`?` placeholders and `Sqlite3.bind/2`. The four interpolated `#{order}` fragments
(lines 120, 166, 193) look alarming but derive from
`if discipline == :fifo, do: "ASC", else: "DESC"` — a boolean over a compile-time
literal pair, with no user input reachable. Not injectable. This is the one place in
the codebase where the data path is done correctly, and it is worth preserving as the
pattern. There are no migrations to review; schema creation is idempotent
`CREATE TABLE IF NOT EXISTS` at line 73.

### I-2 — No compiled-code generation, contrary to first impressions

`CLAUDE.md` describes the compiler as producing "executable rule modules," which would
imply `Code.eval_quoted` or `Module.create` on untrusted input. It does not.
`lib/anemos/compiler.ex:81` is explicit: "executable closures. No code generation, no
Module.create." Verified by grep — there is no `Code.eval*`, no `Code.compile*`, no
`Module.create`, no `EEx`, and no `apply/3` anywhere in `lib/`. This materially limits
the blast radius of malicious policy text to the verbs the host has registered, and it
is the single best security decision in the codebase.

### I-3 — No rate limiting anywhere

No throttling on event dispatch, on `load/2` calls, on schedule creation, or on
capability demands. Every one is an unbounded synchronous `GenServer.call` into a
single dispatcher process, which is the system's global serialization point. Relevant
once an external event source is attached.

### I-4 — Dependency posture is current

`comn` declares 8 direct dependencies; the resolved tree is 27 packages. Versions are
current as of the lock file: `jason` 1.4.4, `req` 0.5.17, `finch` 0.21.0, `mint`
1.7.1, `exqlite` 0.36.0, `gnat` 1.13.1, `nimble_parsec` 1.4.2, `db_connection` 2.10.1.
No retired, abandoned, or known-vulnerable packages identified. All are actively
maintained and widely used. Toolchain is Elixir 1.19.5 / OTP 28 — both current.
`exqlite` compiles a native SQLite via `elixir_make`/`cc_precompiler`, so precompiled
binaries are fetched at build time; verify checksums if the supply chain matters.

### I-5 — Request-id generation is sound

`lib/anemos/runtime/dispatcher.ex:354-356` uses `:crypto.strong_rand_bytes(8)` with
Base32 hex encoding. Correct primitive. 64 bits is adequate for correlation and must
not be relied on as a security token.

---

## 7. Prioritized recommendations

Ordered by risk reduction per unit of effort. The first four are small changes that
close the largest holes.

| # | Action | Addresses | Effort |
| --- | --- | --- | --- |
| 1 | Stop interning unmatched identifiers as atoms in `lexer.ex:504`; use `String.to_existing_atom/1` with rescue at the other five sites | H-4 | Hours |
| 2 | Default-deny in `context_matches?/2` when a rule declares a context and the event has none; compare path segments, not string prefixes | H-2 | Hours |
| 3 | Make unknown capabilities fatal in `Demand.handle_missing/6` regardless of flag | M-1 | Minutes |
| 4 | Add `[:safe]` to the three `binary_to_term/1` calls in `comn`'s SQLite queue | M-4 | Minutes |
| 5 | Enforce capability context: pass the demanding rule's context to `CapabilityServer.execute/2` and reject on mismatch | H-3 | Days |
| 6 | Introduce a redacting secret wrapper type; stop `inspect`ing payloads in `Channel.Logger` and in error paths | H-5, M-3 | Days |
| 7 | Either implement `signed_by` verification or remove the keyword and the `Envelope.signature` field | H-1 | Days / minutes |
| 8 | Add an `arg_schema/1` callback to `Anemos.Runtime.Module` and enforce it in `execute_op/3` before dispatch; confine all path arguments to a configured root | C-2 | Weeks |
| 9 | Gate `Anemos.Runtime.load/2` behind an explicit privileged path; remove `:load` from the `Comn.act/1` surface | C-1 | Days |
| 10 | Clamp scheduler intervals to a minimum, cap schedules per runtime, add a `Duration.to_ms/1` fallback clause | M-2 | Hours |
| 11 | Make `ModuleRegistry.register/3` write-once or require explicit replacement; log every registration | H-6 | Hours |
| 12 | Default NATS to TLS; plumb NKey/JWT credentials | M-5 | Days |
| 13 | Replace SHA-256 key derivation with HKDF-SHA256 and separate signing from encryption keys in `Comn.Secrets.Local` | M-6 | Days |
| 14 | Remove `mix.lock` from `.gitignore`; delete `erl_crash.dump` and the stray root files | M-7, M-8, L-4 | Minutes |

### One structural recommendation

Fixes 1-4 and 10-14 are point repairs and should be done regardless. But items 5-9
keep returning to the same root cause: **Anemos declares a security model — signed
rules, context boundaries, capability gating — and implements none of it, while
already being wired to secret unlocking and infrastructure verbs.**

Before adding language features, decide explicitly which of the following Anemos is:

1. **A trusted-operator engine.** Policy text is as privileged as source code. Then
   delete `signed_by`, stop describing `context` as a boundary, and document loudly
   that `load/2` is equivalent to `eval`. Cheapest, and honest.
2. **A multi-tenant policy engine.** Policy is untrusted input. Then items 5-9 are not
   hardening, they are the product, and they need designing before more surface area
   accumulates.

The current state is the worst of both: the security vocabulary of option 2 with the
trust assumptions of option 1. The parsed-but-ignored `signed_by` keyword is the
clearest symptom, and it is the one that will mislead an operator into trusting a rule
file they should not.

---

## 8. Coverage notes

Reviewed in full: all 39 files in `lib/`, `mix.exs`, `mix.lock`, `config/*.exs`,
`.gitignore`, `.claude/settings.local.json`, `priv/examples/*.rule`.

Reviewed at Anemos's call sites into the path dependency: `Comn.Discovery`,
`Comn.Errors.Registry`, `Comn.Contexts`, `Comn.EventBus`, `Comn.Events.NATS`,
`Comn.Secrets`/`Secrets.Local`/`Secret`, `Comn.Repo.File.Local`, `Comn.Repo.Cmd`/`Cmd.Shell`,
`Comn.Repo.Queue.SQLite`. `comn` was **not** audited in full — findings M-4, M-5, M-6,
and part of C-2 are in that codebase and should be re-raised against it directly.

Not reviewed: `test/` (28 files), `doc/` (generated ExDoc output), `docs/design-notes/`
and `docs/plans/` beyond targeted greps for `signed_by`/signature intent.

No dynamic analysis, fuzzing, or dependency CVE scanning was performed. Running
`mix deps.audit` or `mix hex.audit` against a live advisory database is recommended
and was outside this pass.

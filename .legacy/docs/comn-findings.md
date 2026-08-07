# Security findings in `comn`

Prepared for the maintainer of `comn`. These findings were reached from an audit of
**Anemos**, which depends on `comn` via `{:comn, path: "../comn"}`. No changes were
made to the `comn` repository.

## Scope and provenance

- Repository audited: `/home/imsmith/github/comn`
- Commit examined: `d3d8a4f8f2e1f483abe4525ba2fda0b734b222b5` (2026-06-10)
- Method: static reading of the modules Anemos references or plans to reference. No
  dynamic testing, no fuzzing, no exploit was written.
- `comn` was **not** audited in full. Only the call surface Anemos touches was
  examined: `Comn.Discovery`, `Comn.Errors.Registry`, `Comn.Contexts`, `Comn.EventBus`,
  `Comn.Secrets` / `Comn.Secrets.Local` / `Comn.Secret`, `Comn.Repo.File.Local`,
  `Comn.Repo.Queue.SQLite`, `Comn.Events.NATS`. Absence of findings elsewhere is not
  evidence of absence.

All line numbers below were re-verified against the commit named above.

## Summary

| ID | Finding | Severity | Status vs. prior audit |
| --- | --- | --- | --- |
| C-1 | `binary_to_term/1` without `[:safe]` on disk-backed queue payloads | Medium | Confirmed, line numbers exact |
| C-2 | NATS transport defaults to plaintext, and credentials cannot be plumbed at all | Medium | Confirmed and sharpened |
| C-3 | Key derivation is a bare SHA-256 of an Ed25519 signing key | Medium | Confirmed; nonce handling confirmed correct |
| C-4 | Unconfined caller-supplied paths in `Comn.Repo.File.Local` | Medium | Holds, with two corrections |

Nothing in this set is remotely exploitable by an unauthenticated network peer against
a default `comn` deployment. C-1, C-3 and C-4 all require the attacker to already have
some foothold — write access to a data file, or control of a path or key argument. They
are defence-in-depth failures, not perimeter breaches. C-2 is the one that can put
plaintext credentials on a wire.

## C-1 — Unsafe deserialization of SQLite queue payloads

**Severity: Medium.** Confirmed. The reported line numbers are exact.

`lib/comn/repo/queue/sqlite.ex` deserializes queue payloads read out of a SQLite file
without the `[:safe]` option, at three sites:

```elixir
# lib/comn/repo/queue/sqlite.ex:128  (handle_call(:reserve, ...))
item = :erlang.binary_to_term(payload)

# lib/comn/repo/queue/sqlite.ex:167  (handle_call({:peek, n}, ...))
items = fetch_all(db, sql, [n]) |> Enum.map(fn [payload] -> :erlang.binary_to_term(payload) end)

# lib/comn/repo/queue/sqlite.ex:196  (do_find/4, serving both :find and :remove)
item = :erlang.binary_to_term(payload)
```

The payload is a BLOB column in an ordinary on-disk SQLite database. The path is
caller-supplied at `open/2` (`lib/comn/repo/queue/sqlite.ex:26-32`) and the file is
created with default permissions by `File.mkdir_p!/1` plus `Sqlite3.open/1`
(`lib/comn/repo/queue/sqlite.ex:66-68`).

**Impact.** Anyone who can write that file controls the term stream:

- Atom table exhaustion. The atom table is a fixed-size, non-garbage-collected global
  resource; exhausting it kills the VM. This is a denial of service reachable from a
  data file, which is the reason `[:safe]` exists.
- Injection of pids, ports, refs, and external funs into runtime state. `do_find/4`
  then applies a caller-supplied predicate to the decoded term
  (`lib/comn/repo/queue/sqlite.ex:198`), and `reserve` hands the term back to the
  caller, so a hostile term propagates immediately rather than sitting inert.

**Evidence this is an oversight, not a policy.** Verified. The same repository uses the
flag correctly in three other places:

- `lib/comn/secrets/local.ex:140` — `:erlang.binary_to_term(serialized, [:safe])`
- `lib/comn/secrets/vault.ex:126` — same
- `lib/comn/secret.ex:12` — the protocol's own documented example uses `[:safe]`

The SQLite queue is the outlier.

**Fix.** Add `[:safe]` at all three sites and handle the resulting `ArgumentError`.
`[:safe]` raises rather than returning an error tuple, so a bare flag addition converts
a silent corruption into a `GenServer` crash; wrap it the way `unwrap/2` already does in
`lib/comn/secrets/local.ex:139-151`. Note the one behavioural consequence: `[:safe]`
rejects terms containing atoms that do not already exist in the running VM, so a queue
file written by a node with a larger atom table than the reader will now fail to decode.
For a durable queue that is the correct trade.

**Effort.** Under an hour including tests.

## C-2 — NATS transport defaults to plaintext, and credentials cannot be supplied

**Severity: Medium.** Confirmed, and the underlying defect is worse than reported: it is
not merely that credentials default to absent, it is that a caller **cannot supply them
at all**, and an attempt to do so is silently discarded.

```elixir
# lib/comn/events/nats.ex:45-50
def start_link(opts \\ []) do
  {name, opts} = Keyword.pop(opts, :name, __MODULE__)
  {server_opts, gen_opts} = Keyword.split(opts, [:host, :port, :tls, :ssl_opts])
  server = Map.new(server_opts)
  server = if map_size(server) == 0, do: %{host: "127.0.0.1", port: 4222}, else: server
  GenServer.start_link(__MODULE__, server, [{:name, name} | gen_opts])
end
```

`server` is passed verbatim to `Gnat.start_link/1` at `lib/comn/events/nats.ex:84`.

**The silent-discard mechanism.** `Keyword.split/2` at line 47 keeps only
`:host`, `:port`, `:tls`, `:ssl_opts`. Every other key falls into `gen_opts` and is
passed as a `GenServer` start option, where unrecognized keys are ignored. So a caller
who writes:

```elixir
{Comn.Events.NATS, host: "nats.internal", tls: true, username: "svc", password: "..."}
```

gets a connection with no credentials and no error. The credentials do not reach Gnat
and nothing reports that they were dropped.

**The credentials exist in the dependency.** `gnat` 1.11 negotiates four auth modes,
all of which key off fields in the connection settings map
(`deps/gnat/lib/gnat/handshake.ex:47-79`):

- `%{username: _, password: _}`
- `%{token: _}`
- `%{nkey_seed: _, jwt: _}`
- `%{nkey_seed: _}`

`nkeys` 0.3.0 and `kcl` 1.4.3 are already resolved in `mix.lock:31` and `mix.lock:24` as
transitive `gnat` dependencies, so the NKey/JWT path is available today at zero
packaging cost. `Comn.Events.NATS` plumbs none of it.

**TLS default.** `tls` is absent from the default map, and gnat's own
`@default_connection_settings` sets `tls: false` (`deps/gnat/lib/gnat.ex:118-128`). The
default is therefore cleartext TCP to `127.0.0.1:4222`. The `choices/0` callback at
`lib/comn/events/nats.ex:152-158` advertises exactly `host`, `port`, `tls` — confirming
the omission is in the module's stated contract, not just its implementation.

**Why this matters to the depending project.** `Anemos.Channel`
(`/home/imsmith/github/anemos/lib/anemos/channel.ex:7,23`) documents NATS as an intended
connector, and Anemos's shipped example `priv/examples/ddns.rule:7` emits an unlocked
secret to a channel:

```text
emit [SECRET::unlock(agent.did_meshid_z6MkAgent123.operator.security:did_key_67890)]
  as :katachora.ddns.key
```

If a host wires channel output to `Comn.Events.NATS`, that plaintext secret crosses the
network unencrypted, to a server the client never authenticated. Note also
`lib/comn/events/nats.ex:114`:

```elixir
encoded = if is_binary(payload), do: payload, else: inspect(payload)
```

Non-binary payloads are published as `inspect/1` output, which will happily render the
contents of a struct — including a decrypted secret — as a readable string on the wire.

**Fix.**

1. Widen the `Keyword.split/2` key list to include `:username`, `:password`, `:token`,
   `:nkey_seed`, `:jwt`, `:tcp_opts`, `:connection_timeout`, `:inbox_prefix`. Simpler
   and more future-proof: stop allow-listing, pass the whole option set through to Gnat
   and pop only the keys `Comn` genuinely owns.
2. Fail loudly on unknown keys rather than routing them into `gen_opts`.
3. Change the default to `tls: true`, or at minimum log a warning when a connection is
   established to a non-loopback host with `tls` unset.
4. Update `choices/0` and the `@moduledoc` to describe the credential options.
5. Replace the `inspect/1` fallback with an explicit encode step that errors on
   non-binary input, so no struct is serialized to the wire by accident.

**Effort.** Items 1, 2, 4 are half a day. Item 3 is a breaking default change and needs
a release note. Item 5 is a breaking API change for any caller currently relying on the
`inspect` behaviour; audit callers first.

## C-3 — Key derivation is a bare hash of an Ed25519 signing key

**Severity: Medium.** Confirmed. The code documents its own defect. The reported line is
exact; there is a second, identical site the prior report did not name.

```elixir
# lib/comn/secrets/local.ex:30-33  (lock/2)
# Derive symmetric key from Ed25519 private key
# In production, you'd use proper key derivation (HKDF)
# For now, hash the private key to get 32 bytes for ChaCha20
symmetric_key = :crypto.hash(:sha256, key.private)
```

```elixir
# lib/comn/secrets/local.ex:77-78  (unlock/2)
# Derive same symmetric key
symmetric_key = :crypto.hash(:sha256, key.private)
```

The defects, in order of seriousness:

1. **Key separation violation.** An Ed25519 *signing* private key is used as input
   material for an encryption key. Using one key pair for two cryptographic purposes is
   a standing prohibition; it forecloses any future signing use of the same key and
   couples the confidentiality of every blob to the integrity of the identity key.
2. **No salt, no context separation.** The derivation is a pure function of
   `key.private`. Every blob locked with a given key, for every purpose, across every
   deployment, uses the identical symmetric key. There is no `info`/context string to
   separate purposes.
3. **No rotation path.** Verified: `rotate/1` does not exist. A repository-wide grep for
   `rotate` across `lib/` and `test/` returns nothing. The `Comn.Secrets` behaviour
   declares exactly four callbacks — `lock/2`, `unlock/2`, `wrap/2`, `unwrap/2`
   (`lib/comn/secrets.ex:80,88,115,136`). There is no rotation in the contract.
4. **No key versioning in the ciphertext.** Verified. `Comn.Secrets.LockedBlob` carries
   `cipher`, `encrypted`, `tag`, `key_hint`, `nonce`, `metadata`
   (`lib/comn/secrets/locked_blob.ex:16-21`, `defstruct` at `:66`). `key_hint` is a fingerprint of the
   *public* key (`lib/comn/secrets/key.ex:86`) — it identifies which key, not which
   generation of that key and not which KDF produced the symmetric key. There is no
   version or scheme field, so a future migration to HKDF cannot distinguish old blobs
   from new ones without an out-of-band flag day.
5. `recon/0` advertises the weakness in the module's public introspection surface:
   `key_derivation: :sha256` (`lib/comn/secrets/local.ex:204`).

**Nonce handling: correct.** Confirmed, not refuted. `lib/comn/secrets/local.ex:36`
generates a fresh 12-byte nonce per `lock/2` call via
`:crypto.strong_rand_bytes(12)`, the nonce is stored on the blob
(`lib/comn/secrets/local.ex:61`) and reused only for the matching decrypt
(`lib/comn/secrets/local.ex:87`). 96-bit random nonces with ChaCha20-Poly1305 are
standard practice and the birthday bound is not a practical concern at any plausible
blob volume. The AEAD construction itself is sound: metadata is bound as associated data
at `lib/comn/secrets/local.ex:45` and `:81`, and tag failure is handled explicitly at
`:96-97`.

Because the nonce is fresh per operation, the single-symmetric-key problem does **not**
degenerate into the catastrophic keystream-reuse failure. The exposure is the
narrower one: total loss of confidentiality for every blob ever locked, if that one
derived key is recovered, with no mechanism to rotate out of it.

**Fix.**

1. Derive with HKDF-SHA256: a random per-blob salt stored on the `LockedBlob`, and an
   `info` string carrying a purpose/context label. `:crypto.mac(:hmac, :sha256, ...)`
   is sufficient to implement HKDF; no new dependency is required.
2. Separate signing from encryption. Either generate an independent X25519 key for
   encryption, or derive the encryption key from a distinct root, and stop reading
   `key.private` of an Ed25519 identity key for cipher input.
3. Add a `kdf` or `version` field to `LockedBlob` before shipping the change, so old
   blobs remain decryptable and new ones are distinguishable.
4. Add `rotate/1` to the `Comn.Secrets` behaviour, or state explicitly in the
   `@moduledoc` that rotation is out of scope so consumers do not assume it exists.

**Effort.** Days, not hours — items 1 and 2 are straightforward, but item 3 is a
persisted-format change and needs a migration path plus round-trip tests against blobs
written by the current code. Do not ship 1 and 2 without 3.

## C-4 — Unconfined caller-supplied paths in `Comn.Repo.File.Local`

**Severity: Medium.** The finding holds. Two details in the prior report need
correction.

`lib/comn/repo/file/local.ex` performs filesystem operations on a `path` that arrives
from the caller and is never normalized, resolved, or confined to a root:

```elixir
# lib/comn/repo/file/local.ex:32   (open/2)
case File.open(path, mode) do

# lib/comn/repo/file/local.ex:76   (stream/2)
{:ok, File.stream!(path)}

# lib/comn/repo/file/local.ex:111  (write/3)
case IO.write(handle, data) do

# lib/comn/repo/file/local.ex:164  (delete/2)
def delete(%FileStruct{path: path}, _opts) do
  File.rm(path)
end

# lib/comn/repo/file/local.ex:170  (observe/2)
File.stream!(path)
```

**Corrections to the prior report.**

- The cited lines 29, 75, 86, 110 are the `def` lines; the calls are at 32, 76, and 111.
- There is no `File.write` call. `write/3` uses `IO.write/2` on an already-open handle
  (line 111) — the path check must therefore happen at `open/2`, not at `write/3`.
- The prior report missed two sites: `delete/2` calls `File.rm/1` at line 164 on an
  unconfined path, and `observe/2` calls `File.stream!/1` at line 170. `delete/2` is the
  most damaging of the set, and unlike the others it does not even require the file to
  be in a `:loaded` state.

**Impact.** There is no traversal defence of any kind: no `Path.expand/2` against a
root, no symlink resolution, no rejection of `..` segments, no allow-listed prefix. Read,
write-truncate, and unlink all follow whatever the caller passes. The `act/1` entry
points make this a one-call surface:

```elixir
# lib/comn/repo/file/local.ex:201-217
def act(%{action: :read, path: path}) do    # arbitrary read
def act(%{action: :write, path: path, data: data}) do  # opens [:write, :binary] — truncates
```

`act(%{action: :write, ...})` opens with mode `[:write, :binary]`, which truncates an
existing file. An attacker who controls the path therefore gets arbitrary file
destruction, not merely arbitrary creation.

**Blast radius today.** Nil within `comn`'s own supervision tree, and nil in Anemos as
shipped — see the call-site analysis below. This is a latent defect waiting on a
consumer that passes untrusted paths.

**Fix.** Add root confinement at the module's boundary: an `:root` option (or
application env) naming a base directory, and a single `resolve/2` helper that expands
the caller path against that root, resolves symlinks with `File.read_link/1` or
`Path.safe_relative/2`, and rejects anything that escapes. Apply it at `open/2`,
`stream/2`, `delete/2`, and `observe/2` — every function that touches `path` — and
return `repo.file/path_outside_root` from `Comn.Errors.Registry` on rejection. Applying
it only at `open/2` is insufficient because `stream/2`, `delete/2`, and `observe/2` read
`path` off the struct rather than re-deriving it from the handle.

Consider also whether `delete/2` should require the `:loaded` state, as every other
mutating function does. Its current signature matches any `%FileStruct{}` regardless of
state, which is inconsistent with the documented lifecycle state machine.

**Effort.** Half a day for the helper plus its tests. Longer if `Comn.Repo.File.NFS`
delegates here and needs the same treatment — that was not examined.

## Anemos call sites and blast radius

For the `comn` maintainer's triage. Anemos on branch
`hardening/supervision-and-trust-boundary` references `comn` at these points:

| `comn` API | Anemos call site | Reaches a finding? |
| --- | --- | --- |
| `Comn.Errors.Registry.discover/0` | `lib/anemos/application.ex:35` | No |
| `Comn.Discovery.discover/0` | `lib/anemos/application.ex:36` | No |
| `use Comn.Errors.Registry` | `lib/anemos/runtime/errors.ex:10` | No |
| `Comn.Errors.Registry.error!/2` | `lib/anemos/runtime/dispatcher.ex:437,494`, `lib/anemos/module.ex:88` | No |
| `Comn.Contexts.with_context/2`, `ContextStruct.new/1` | `lib/anemos/runtime/dispatcher.ex:151,351` | No |
| `Comn.EventBus.broadcast/2` | `lib/anemos/channel/comn_bus.ex:25` | No |

**Findings C-1, C-3, and C-4 are not currently reachable from Anemos code.** Anemos
contains no call to `Comn.Repo.Queue.SQLite`, `Comn.Secrets`, `Comn.Secrets.Local`, or
`Comn.Repo.File.Local`. They are reachable in intent only:

- C-4 becomes live when Anemos implements the `FILE` verb module
  (`lib/anemos/runtime/modules/file.ex` exists as a placeholder). At that point
  `[FILE::read "../../etc/shadow"]` is a working traversal on day one.
- C-3 becomes live when a `SECRET` verb module is wired to `Comn.Secrets`. The
  `priv/examples/ddns.rule:7` example already invokes `SECRET::unlock`.
- C-1 becomes live if Anemos adopts the SQLite queue for durable demand scheduling.
- C-2 becomes live as soon as any host registers a NATS channel connector.

The prudent reading is that all four should be fixed before the corresponding Anemos
work lands, not after.

## Additional observations

These fall short of the four findings above but were noted while reading the call sites
Anemos actually exercises.

**`Comn.Discovery.discover/0` invokes callbacks on every loaded module.** At
`lib/comn/discovery.ex:131-135`, `discover/0` iterates `:code.all_loaded/0` and calls
`build_meta/1` on every module that passes `comn_module?/1`. Any module in the code path
that happens to export the `Comn` callbacks gets its `look/0` and `recon/0` executed at
boot. This is code that is already loaded into the VM, so it is not a privilege
boundary crossing, but it does mean a dropped-in `.beam` file executes at
application start rather than at first call. Worth a note in the `@moduledoc` at
minimum. `Comn.Errors.Registry.discover/0` has the same shape at
`lib/comn/errors/registry.ex:283-286`.

**`Comn.Repo.Cmd.Shell` is a declared but unimplemented execution backend.** It is
discovered and advertised via `recon/0` (`lib/comn/repo/cmd/shell.ex:22-24`) while
`act/1` returns `{:error, :not_implemented}` (line 30). When it lands it will inherit
the same unconfined-input problem as C-4, but with command execution rather than file
access as the consequence. Design the confinement model before writing the
implementation, not after.

**A documentation error in Anemos, reported here for completeness.** Anemos's
`lib/anemos/module.ex:14-15` documents `&Comn.Secret.unlock/2` and
`&Comn.Secret.rotate/1` as example verb handlers. `Comn.Secret` is a *protocol*
(`lib/comn/secret.ex:1`) exposing only `to_blob/1` and `from_blob/1`; neither `unlock/2`
nor `rotate/1` exists on it. This is Anemos's bug to fix, not `comn`'s, and is noted
only so the `comn` maintainer is not misled about their own API surface.

# `Anemos.Runtime.TrustStore`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/trust_store.ex#L1)

Per-runtime trust configuration: a keyring of **public** verification
keys, and the policy for sources that declare no signer at all (A-05).

One of these is started for every `Anemos.Runtime`, whether or not the
embedder configures anything. That is deliberate: a runtime that has no
trust store is a runtime `Anemos.Runtime.LoadAuthority.Signed` cannot
make a decision about, and the only safe answer to "I cannot decide" on
a security boundary is refusal. Always starting one means refusal is
reserved for genuine failures rather than being the normal case.

## Public keys only, and it is enforced here

A key handed to this store must have `private: nil`. This is not
hygiene, it is the invariant the whole design rests on: `comn` finding
C-3 records that the Ed25519 *signing* private key is currently reused
as ChaCha20 encryption key material, a key-separation violation. A
verifier that never holds a private key cannot compound that mistake,
and cannot be quietly extended into a signer later. Anemos verifies;
something else signs.

A key carrying private material is therefore refused — loudly, at
ingest, by `start_link/1` raising and by `put_key/3` answering
`{:error, :private_key_material}` — rather than accepted and ignored.

## What this store does *not* decide

Which algorithms are acceptable. A `Comn.Secrets.Key` may declare
`:rsa_4096` or `:ecdsa_p256`, and this store will hold one; it is
`Signed` that refuses to verify against it, explicitly, on the load
path. The split is intentional — refusing private material protects an
invariant of *the store*, whereas which signatures count is *the
verifier's* policy, and putting it here would hide the refusal from the
load that triggered it.

## Signer names are strings

`signed_by :operator` reaches an authority as the **string**
`"operator"`, not the atom `:operator` — the lexer's atom token payload
is a binary and `Anemos.Parser` passes it straight through. A keyring
keyed on atoms would therefore never match, and a verifier that never
matches a signer is one that never rejects one: fail-open, on the
boundary itself. Every name entering this store is normalised to a
binary so that either spelling in configuration behaves identically.

## Options

  * `:name` — process registration name.
  * `:keyring` — `%{signer_name => Comn.Secrets.Key.t()}`. Names may be
    atoms or strings; they are stored as strings. Defaults to empty,
    which means every declared signer is unknown, which means refused.
  * `:unsigned_policy` — `:strict | :warn | :permit`, default
    `:permit`. See `unsigned_policy/1`.

# `keyring`

```elixir
@type keyring() :: %{optional(String.t()) =&gt; Comn.Secrets.Key.t()}
```

Signer name to public key. Names are always binaries.

# `unsigned_policy`

```elixir
@type unsigned_policy() :: :strict | :warn | :permit
```

What to do with a source that names no signer at all.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `delete_key`

```elixir
@spec delete_key(atom(), atom() | String.t()) ::
  :ok | {:error, Comn.Errors.ErrorStruct.t()}
```

Removes the key trusted for `signer`. Revocation.

# `fetch`

```elixir
@spec fetch(atom()) ::
  {:ok, %{keyring: keyring(), unsigned_policy: unsigned_policy()}}
  | {:error, Comn.Errors.ErrorStruct.t()}
```

Returns the whole trust configuration for `runtime`.

An `anemos.trust/no_trust_store` error when the runtime has none — which a caller
on the load path must treat as a refusal, not as an absence of policy.

# `key`

```elixir
@spec key(atom(), atom() | String.t()) :: {:ok, Comn.Secrets.Key.t()} | :error
```

Looks up the public key trusted for `signer` in `runtime`.

`signer` may be an atom or a string; both resolve to the same entry.
`:error` means the signer is unknown, and an unknown signer is refused
rather than permitted — under multi-tenancy, a name nobody has vouched
for is a name with no authority behind it.

# `name_for`

```elixir
@spec name_for(atom()) :: atom()
```

The registered name of the trust store belonging to `runtime`.

# `put_key`

```elixir
@spec put_key(atom(), atom() | String.t(), Comn.Secrets.Key.t()) ::
  :ok | {:error, Comn.Errors.ErrorStruct.t()}
```

Adds or replaces the public key trusted for `signer`. Supports rotation
without restarting the runtime.

Answers an `anemos.trust/private_key_material` error rather than raising, because
unlike `start_link/1` this runs against a live system and a rejected
rotation should not take the runtime down with it. The old key stays in
force, which is the fail-safe outcome.

# `start_link`

```elixir
@spec start_link(keyword()) :: Agent.on_start()
```

Starts a trust store.

Raises `ArgumentError` on a keyring entry carrying private key material
or on an unrecognised `:unsigned_policy`. Both are configuration
mistakes on a security boundary, and a boundary that silently corrects
its own configuration is not one.

# `unsigned_policy`

```elixir
@spec unsigned_policy(atom()) :: unsigned_policy()
```

Returns the unsigned-rule policy in force for `runtime`.

  * `:strict` — refuse a source that declares no signer.
  * `:warn` — admit it, and log that it was admitted unverified.
  * `:permit` — admit it silently. The default; see the module note.

A runtime with no trust store reports the default, because this is a
question about *policy* rather than a decision about a load; the load
path itself fails closed via `fetch/1`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

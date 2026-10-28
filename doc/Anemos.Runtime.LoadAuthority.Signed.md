# `Anemos.Runtime.LoadAuthority.Signed`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/load_authority/signed.ex#L1)

A load authority that verifies detached Ed25519 signatures over the
policy source (A-05).

## What was wrong

`signed_by :operator` was parsed into rule metadata and read by nothing.
A rule declaring it looked authenticated to every human and every tool
that inspected the file, and was installed identically to one that
declared nothing. That manufactures false provenance, which is worse
than having no signing at all — an unsigned file at least tells the
truth about itself.

## The shape of the check

`Anemos.Runtime.LoadAuthority.authorize/1` runs *after* the source is
parsed and *before* it is compiled. After, because parsing is the only
thing that can produce the `signed_by` names; before, because compiling
is what turns text into closures, and nothing unauthorized should get
that far. That is precisely the position a signature check needs, so
this is an authority implementation and required no change to
`Anemos.Runtime.load/3`, to `Anemos.Runtime.LoadRequest`, or to the
behaviour.

The signature is **detached**: it travels in the existing
`:authorization` option, not in the source. `signed_by` continues to
carry identity only, and the `.rule` file stays clean and diffable.

    Anemos.Runtime.load(:anemos, source,
      authorization: %{signatures: %{"operator" => sig}})

A single-signer shorthand is accepted too, and resolves to the sole
declared signer:

    Anemos.Runtime.load(:anemos, source, authorization: %{signature: sig})

Each signature is a raw 64-byte Ed25519 signature or its Base64
encoding, computed over the **exact source bytes** — the same
`request.source` the parser was handed, byte for byte, whitespace and
all. Anything else and a re-serialised source could verify against a
signature made over different text.

Other keys in the `:authorization` map are ignored, so this composes
with an authority scheme that also carries a tenant or a token.

## Public keys only, deliberately

Keys come from `Anemos.Runtime.TrustStore`, which holds
`Comn.Secrets.Key` structs with `private: nil` and refuses anything
else. Producing signatures is explicitly **out of scope for this
repository**: Anemos verifies, something else signs.

That is not squeamishness. `comn` finding C-3 records that the Ed25519
signing private key is currently reused as ChaCha20 encryption key
material — a key-separation violation. A verifier that never holds a
private key cannot compound it. Do not "helpfully" add a signing
function here later; add it to whatever owns the private key, which is
not this runtime.

Only `:ed25519` keys verify. `Comn.Secrets.Key` also declares
`:rsa_4096` and `:ecdsa_p256`; a signer whose key is one of those is
**refused by name**, not skipped, because a signer that is silently
never checked is a signer that can never fail.

## Every decision fails closed

| Situation | Verdict |
| --- | --- |
| Runtime has no trust store | refused |
| Signer not in the keyring | refused |
| Signer declared, no signature supplied | refused |
| Signature not 64 bytes, raw or Base64 | refused |
| Key is not Ed25519 | refused |
| Signature does not verify | refused |
| No `signed_by` anywhere | per `:unsigned_policy` |

An unknown signer is refused rather than permitted because under the
multi-tenant decision a name nobody has vouched for is a name with no
authority behind it. Permitting it would let any tenant mint provenance
by inventing a signer.

## Multiple signers are conjunctive — *all* must verify

A source whose rules declare `:operator` and `:auditor` must carry a
valid signature from both. Not one, not a quorum: both.

The alternative reading — any one signature suffices — is weakened by
the attacker rather than by the defender. Under it, adding a
`signed_by` naming a key you already control turns a source you could
not get loaded into one you can, and the union of every named signer's
trust becomes available to whoever names the most. Conjunctive is the
only reading where adding a name to a source cannot make it easier to
load.

Note that the signature covers the *whole source*, so per-rule
attribution is not representable: `signed_by` names who must have
signed the file, not which rule they vouched for. A source that names
any signer is never treated as unsigned, whatever `:unsigned_policy`
says — it is making a provenance claim, and `:permit` must not launder
it.

## Where `signed_by` may be written

At **source level**, outside any declaration, which is the placement
that matches what the signature covers:

    signed_by :operator

    condition night { ... }

It is also still accepted as rule metadata, where it means the same
thing — a signer the whole source must carry — because that is what it
has always meant and every policy already written against it keeps
working. The two placements are unioned by
`Anemos.Runtime.LoadAuthority.signers/1`.

Source level exists because rule metadata was the *only* placement
(A-60), so a source carrying no `rule` — conditions, capabilities, data
blocks — could not make a provenance claim and `:strict` could never
load one. Since condition bodies execute side effects, such a file is a
full payload, so exempting it from `:strict` was not available either.

## Configuring it

    config :anemos, :load_authority, Anemos.Runtime.LoadAuthority.Signed

    {Anemos.Runtime,
      name: :anemos,
      keyring: %{"operator" => operator_public_key},
      unsigned_policy: :strict}

Refusals surface through `Anemos.Runtime.load/3` as a
`Comn.Errors.ErrorStruct` with code `anemos.runtime/load_denied` —
`:auth`, which is what a signature failure is. The reason names the
signer and the failure mode and carries no key material.

# `refusal`

```elixir
@type refusal() ::
  {:no_trust_store, atom()}
  | {:unknown_signer, String.t()}
  | {:missing_signature, String.t()}
  | {:malformed_signature, String.t()}
  | {:unsupported_algorithm, String.t(), atom()}
  | {:bad_signature, String.t()}
  | {:unsigned, :strict}
```

Why a load was refused, inside this module. `decide/1` answers the same
thing as a structured error whose code ends in the tag.

# `decide`

```elixir
@spec decide(Anemos.Runtime.LoadRequest.t()) ::
  :ok | {:error, Comn.Errors.ErrorStruct.t()}
```

The verdict. A refusal is a structured error whose `code` is
`anemos.trust/<mode>` — the modes are `t:refusal/0`'s tags — and whose
`field` is the signer it concerns, where there is one.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

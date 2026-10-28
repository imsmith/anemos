# `Anemos.Runtime.LoadAuthority`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/load_authority.ex#L29)

The trust boundary on loading policy (A-12).

`Anemos.Runtime.load/3` takes an arbitrary string, compiles it to
closures, and installs it into a live dispatcher. Whoever controls that
string controls every verb the host has registered — including, per the
worked example in `Anemos.Module`, the one that unlocks credentials.
Under the multi-tenant decision that makes loading *the* privileged
operation of the runtime, and this module is where the privilege is
checked.

## What the gate actually consists of

Three things, and it is worth being precise about which of them is a
boundary and which is hygiene:

1. **Loading is no longer reachable from the generic action surface.**
   The runtime's `act` callback used to accept `%{action: :load, ...}`, so
   anything that could reach the Comn action dispatcher could install
   policy. It no longer does, and `choices/0` no longer advertises it.
   This is a real reduction in reachability.

2. **Loading names its authority.** `load/3` consults the module
   configured as `config :anemos, :load_authority`, handing it an
   `Anemos.Runtime.LoadRequest`. That is what makes a load
   *distinguishable* — an embedder can point the authority at a token, a
   mTLS peer identity, a keyring, or a flat refusal, and every load in
   the system goes through it. In-VM this is an API boundary, not a
   sandbox: a caller who already has the BEAM can call the dispatcher
   directly. The boundary that matters is the one between the runtime and
   whatever accepts policy from outside it, and this is the seam that
   boundary attaches to.

3. **A ceiling no authority can waive.** `config :anemos,
   :max_policy_bytes` (default 1 MiB) is checked before the source is
   parsed, and is checked whether the authority permits or not. An
   authority is an authorization decision; a resource ceiling is not
   something an authorization decision should be able to lift.

## The default is permissive, and says so

`Anemos.Runtime.LoadAuthority.Permissive` grants everything, which
preserves the contract every current embedder was written against. It is
named rather than implicit precisely so that "we never configured an
authority" is a visible fact — `configured/0` and
the runtime's `recon` callback both report it — rather than an absence nobody
notices. An operator running multi-tenant is expected to replace it.

## Writing one

    # in a module declaring @behaviour Anemos.Runtime.LoadAuthority
    @impl true
    def authorize(%{authorization: %{tenant: t}, signers: signers}) do
      if Enum.all?(signers, &MyApp.Keyring.trusted?(t, &1)) do
        :ok
      else
        {:error, :untrusted_signer}
      end
    end

    def authorize(_request), do: {:error, :unauthenticated}

Refuse by default and permit explicitly, not the other way round: an
authority whose fallthrough clause returns `:ok` is not an authority.

## Where A-05 slotted in

`authorize/1` runs *after* the source is parsed, which is the only reason
`LoadRequest.signers` can be populated at all. Signature verification is
therefore an authority implementation — it needs the signer names, the
source bytes to verify against, and a keyring, and it has all three. It
landed as `Anemos.Runtime.LoadAuthority.Signed` and required no change to
`load/3`, to `LoadRequest`, or to this behaviour, which is the evidence
the seam was in the right place.

# `verdict`

```elixir
@type verdict() :: :ok | {:error, atom() | String.t() | Comn.Errors.ErrorStruct.t()}
```

An authority's verdict.

`:ok` permits the load. `{:error, reason}` refuses it; `reason` is logged
and named in the caller's error, so it must not carry a credential.

# `authorize`

```elixir
@callback authorize(request :: Anemos.Runtime.LoadRequest.t()) :: verdict()
```

Decides whether `request` may be installed into the runtime. Refuse by default.

# `authorize`

```elixir
@spec authorize(Anemos.Runtime.LoadRequest.t()) :: verdict()
```

Asks the configured authority to authorize `request`.

# `check_size`

```elixir
@spec check_size(String.t()) :: :ok | {:error, Comn.Errors.ErrorStruct.t()}
```

Enforces the ceiling. Runs before the source is parsed and regardless of
the authority.

# `configured`

```elixir
@spec configured() :: module()
```

Returns the configured authority module.

## Examples

    iex> Anemos.Runtime.LoadAuthority.configured()
    Anemos.Runtime.LoadAuthority.Permissive

# `gate`

```elixir
@spec gate(atom(), String.t(), keyword()) ::
  {:ok, Anemos.AST.Program.t()} | {:error, Comn.Errors.ErrorStruct.t()}
```

The gate. Checks the ceiling, parses, and authorizes; returns the AST.

**This is the only supported way to obtain an AST for the compiler.**
That property is the point of the function, and it is stronger than any
amount of documentation asking callers not to skip the boundary. A
caller that parses on its own and compiles the result has reimplemented
a subset of loading and skipped the authority — which is precisely what
`Anemos.run/2` did (A-59), and the same shape as A-39, where `nextrule`
reimplemented a subset of dispatch and skipped the context filter. Both
were fixed by making one path the only path. Two assemblies of the same
`LoadRequest` would reintroduce it at the next field added to the
struct, so there is one.

## Order, and why it is that order

1. **Ceiling first**, before the parser is handed anything. Bounding
   what an untrusted caller can make the parser allocate is the entire
   point of having a ceiling; checking it after the parse would be
   checking it after the damage.
2. **Parse second.** This is what makes `signers` exist at all.
3. **Authority third** — after the parse, because `LoadRequest.signers`
   is the A-05 seam and cannot be populated any earlier; before the
   compile, because compiling is what turns text into closures and
   nothing unauthorized should get that far. Compiling is the caller's
   job, and it happens on the AST this function returns.

## `runtime`

Names which runtime the load is destined for, so an authority can decide
per tenant. `Anemos.run/2` passes `:standalone`: it builds a throwaway
dispatcher and tears it down again, so it is not loading into any named
runtime and does not claim to be. An authority keying on `runtime`
therefore sees the standalone path as its own thing and can refuse it
outright — the correct default for a host that only means to permit
loads into a runtime it named.

## Options

  * `:authorization` — passed through as `LoadRequest.authorization`. A
    token, a peer identity, whatever the configured authority checks.

## Return values

`{:ok, ast}` when the load may proceed. `{:error, reason}` otherwise:
a refusal — by the ceiling or by the authority — is a
`Comn.Errors.ErrorStruct` with code `anemos.runtime/load_denied`, while
a parse failure keeps whatever shape `Anemos.Parser.parse/1` returned.
The two are worth telling apart: one is a boundary decision, the other
is a broken rule file.

## Examples

    iex> {:ok, ast} = Anemos.Runtime.LoadAuthority.gate(:demo, ~s(rule r { when EV { log "hi" } }), [])
    iex> length(ast.declarations)
    1

    iex> Application.put_env(:anemos, :max_policy_bytes, 4)
    iex> {:error, err} = Anemos.Runtime.LoadAuthority.gate(:demo, ~s(rule r { when EV { log "hi" } }), [])
    iex> Application.delete_env(:anemos, :max_policy_bytes)
    iex> err.code
    "anemos.runtime/load_denied"

# `max_bytes`

```elixir
@spec max_bytes() :: pos_integer()
```

Returns the configured source-size ceiling in bytes.

# `signers`

```elixir
@spec signers(Anemos.AST.Program.t() | term()) :: [atom() | String.t()]
```

Collects the `signed_by` names an AST declares, from both placements.

Source-level `signed_by` (A-60) is the one that describes what a detached
signature actually covers, and the only one available to a source carrying no
`rule`. Rule-level `signed_by` is still read: it names a signer the whole
source must carry, which is what it always did, and dropping it would silently
weaken every policy already written against it.

The two are unioned and de-duplicated. All named signers are required — see
`Anemos.Runtime.LoadAuthority.Signed` on why that is conjunctive — so which
placement a name arrived by cannot change the decision.

Empty when nothing in the source claims a signer, which is itself a fact
an authority may want to refuse on.

## Examples

Source level, on a file that declares no rule at all — the case rule-only
syntax made impossible:

    iex> {:ok, ast} = Anemos.Parser.parse("signed_by :operator\ncondition c { when EV { log \"x\" } }")
    iex> Anemos.Runtime.LoadAuthority.signers(ast)
    ["operator"]

Both placements union, and a name declared twice is counted once:

    iex> {:ok, ast} = Anemos.Parser.parse("signed_by :operator\nrule r { signed_by :auditor\nwhen EV { log \"x\" } }")
    iex> Enum.sort(Anemos.Runtime.LoadAuthority.signers(ast))
    ["auditor", "operator"]

    iex> {:ok, ast} = Anemos.Parser.parse("signed_by :op\nrule r { signed_by :op\nwhen EV { log \"x\" } }")
    iex> Anemos.Runtime.LoadAuthority.signers(ast)
    ["op"]

A source claiming nothing answers `[]`, which is what `:unsigned_policy`
acts on:

    iex> {:ok, ast} = Anemos.Parser.parse("rule r { when EV { log \"x\" } }")
    iex> Anemos.Runtime.LoadAuthority.signers(ast)
    []

---

*Consult [api-reference.md](api-reference.md) for complete listing*

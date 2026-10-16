# 10. Deploying and operating policies

A useful policy becomes part of a running system. Operators need to know
whether a load succeeded, what an edit replaces, which state survives, and
who is allowed to install code. These are application contracts as much as
language features.

## Give deployed sources stable identities

```elixir
source = File.read!("policies/garage.rule")
Anemos.Runtime.load(:anemos, source, policy: "garage.rule")
```

A named load replaces the previous contents of that policy identity.
Declarations removed from the source are removed from the runtime. Unchanged
rules and conditions keep their state; changed declarations start fresh.
Source fingerprints ignore line positions, so moving unchanged text down
the file does not itself reset the declaration. Changing a declaration's
actual parsed content can reset it even if the change seems operationally
minor.

Names are also protected across policies. A rule, condition, or capability
owned by one named policy cannot be silently taken by another named load.
An anonymous load cannot replace a name owned by a named policy either.
Resolve ownership conflicts before deploying.

Without `policy:`, loading is anonymous: declarations accumulate, and rules
are replaced by name. Anonymous loads are useful for exploration, but they
do not express a complete file replacement or give you a policy ID to unload.
Use named policies for a managed deployment.

## Handle all three load outcomes

```elixir
case Anemos.Runtime.load(:anemos, source, policy: "garage.rule") do
  :ok ->
    :ready

  {:partial, failures} ->
    {:needs_attention, failures}

  {:error, reason} ->
    {:not_deployed, reason}
end
```

`:ok` means the policy installed and its declarations loaded successfully.
`{:error, reason}` means nothing from this attempted load was installed; an
existing deployment remains active. Parse failure, compile failure, rejected
authority, excessive source size, and ownership conflicts can produce errors.

`{:partial, failures}` means the policy **did install**, but some declarations
are inert. Schedules may not have armed or datasets may not have initialized.
Other rules and capabilities in that source are present. This is not a
rollback and must not be reported to operators as one. A successful load is
also not an exhaustive application validation: unknown command modules and
query engines may only be discovered when called.

List or remove deployments with:

```elixir
Anemos.Runtime.policies(:anemos)
Anemos.Runtime.unload(:anemos, "garage.rule")
```

Unload removes owned declarations, rule state, global data, subscriptions,
and schedules no other policy needs. The direct host API is not authority
gated; restrict who can call it. The runtime's `POLICY::unload` verb requests
an unload from an already admitted policy; the request is completed after
the active dispatch. Its returned acknowledgement is not proof the target
has already disappeared.

## Deploy a directory

```elixir
{Anemos.Runtime,
 name: :anemos,
 modules: %{"DEVICE" => MyApp.Device},
 watch: "/etc/my_app/policies"}
```

The watcher recursively polls for `*.rule` files. A path relative to that
directory becomes the policy ID. Saving deploys; deleting unloads. A missing
directory is not treated as an empty one, so it does not erase the deployment.
A file that fails a load leaves its last good version running and is retried
on later scans. A partial load is still a deployed policy with failures to
inspect.

```elixir
watcher = Anemos.Runtime.watcher_name(:anemos)
Anemos.Runtime.Watcher.status(watcher)
Anemos.Runtime.Watcher.scan(watcher)
```

The default polling interval is 1,000 ms. To configure it or scan manually,
start `Anemos.Runtime.Watcher` separately under your supervisor with
`runtime:`, `dir:`, and `interval_ms:` (`:manual` disables automatic polling).
Register required modules and data/feed handlers before dependent policies
are loaded. A module map can be supplied at runtime startup; custom data/feed
registration may require startup sequencing before starting the watcher.

## Authorize policy loads

A policy can invoke registered host verbs. Treat loading it as installing
code with access to those verbs. The public loading paths, including
`Anemos.run/2` and the CLI, check a source-size limit and consult the configured
load authority. The default authority is permissive.

A custom authority implements `Anemos.Runtime.LoadAuthority.authorize/1` and
receives an `Anemos.Runtime.LoadRequest` with source, byte size, runtime name,
policy ID, declared signers, and the caller's `authorization` term. Return
`:ok` to admit or `{:error, reason}` to refuse. Configure the module:

```elixir
config :anemos, :load_authority, MyApp.PolicyAuthority
```

Pass its credentials explicitly:

```elixir
Anemos.Runtime.load(:anemos, source,
  policy: "garage.rule",
  authorization: %{tenant: "acme", token: token})
```

One-shot execution presents runtime `:standalone` to the authority. A host
can refuse that path independently of named runtimes. The authority boundary
does not isolate hostile host Elixir code already running inside the VM.

## Verify signed source

The bundled signed authority verifies detached Ed25519 signatures. Select it
in application configuration:

```elixir
config :anemos, :load_authority, Anemos.Runtime.LoadAuthority.Signed
```

Start a runtime with public keys and an explicit unsigned policy:

```elixir
{Anemos.Runtime,
 name: :anemos,
 keyring: %{"operator" => operator_public_key},
 unsigned_policy: :strict}
```

`operator_public_key` is a `Comn.Secrets.Key` containing the public Ed25519
key and no private key. The signing system supplies it; Anemos does not
generate or hold signing private keys. `:strict` refuses unsigned sources,
`:warn` admits and warns, and `:permit` admits without requiring a signer.
The default unsigned setting is `:permit`.

Declare the signer at source level:

```anemos
signed_by :operator

rule greet {
  when HELLO { log "Hello" }
}
```

Then supply a detached signature over the **exact source bytes**, including
the declaration and whitespace:

```elixir
Anemos.Runtime.load(:anemos, source,
  policy: "greeting.rule",
  authorization: %{signatures: %{"operator" => signature}})
```

A signature is raw 64-byte Ed25519 data or its Base64 encoding. With one
declared signer, `%{signature: signature}` is also accepted. Every declared
signer must verify. Unknown signers, absent signatures, unsupported key types,
and bad signatures are refused; an unsigned-permit setting does not waive a
declared signer's check. `signed_by` is an identity claim, not a signature
by itself, and only an enforcing authority gives that claim meaning.

The watcher reads a Base64 signature from `<file>.sig`. It supports one
signature per source file; sources requiring several signers must use
`Runtime.load/3`. Replacing the sidecar triggers a new deployment attempt.

Rule metadata also accepts `signed_by`; it still means a signer for the
whole source. Source-level placement makes that scope clearer and also works
for a source containing only conditions or data.

## Understand recovery boundaries

The runtime owns an in-memory state table that outlives its worker processes.
Supported dispatcher/scheduler/condition restarts preserve rule `set`
bindings, condition values and reports, module registrations, deployment
definitions, and timer/firing state held there. The supervision tree rebuilds
dependent workers from that retained information.

This is crash recovery inside a running supervisor, not disk persistence.
Stopping the entire runtime or restarting the VM loses in-memory state.
External side effects already performed are not rolled back; replaying an
event can perform them again. Keep durable business records in host services,
and give side-effecting operations application-level idempotency keys when
replay is possible.

## Resource limits and observability

| Setting or limit | Default | Purpose |
| --- | --- | --- |
| `:max_policy_bytes` | 1,048,576 | Bound source before parsing |
| `:min_schedule_interval_ms` | 1,000 | Reject excessive interval frequency |
| `:max_schedules` | 1,000 | Bound armed timers per scheduler |
| Dispatch `timeout:` | 5,000 ms | Bound how long a caller waits |
| `while` iterations | 10,000 | Bound one loop |
| Event dispatch depth | 10,000 | Bound handoff/emit recursion |
| Retained dispatch trace | 200 entries | Recent execution history |

The first three are application settings under `:anemos`. Set them in
application configuration before starting/loading. Dispatch timeouts are call
options, for example `Runtime.dispatch(:anemos, "GO", %{}, timeout: 10_000)`.
A caller timeout is not cancellation or rollback of host work. The dispatcher
is synchronous; slow host verbs delay other work. Put long-running operations
behind host services that return an acknowledgement and later emit completion
events.

Use `Runtime.describe/1`, `Runtime.explain/3`, and `Runtime.trace/2` as
described next to distinguish a healthy interpreter from a policy that is
loaded but unable to do useful work.

[Next: Finding and fixing problems](11-troubleshooting.md) · [Contents](README.md)

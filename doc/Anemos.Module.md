# `Anemos.Module`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/module.ex#L1)

Macro for defining Anemos modules — named sets of verb handlers.

Most modules are thin wrappers around existing functions. This macro
eliminates the boilerplate of implementing the `Anemos.Runtime.Module`
behaviour by hand.

## Usage

    # lib/my_app/anemos/secret.ex — inside MyApp.Anemos.Secret
    use Anemos.Module, name: "SECRET"

    verb :unlock, &MyApp.Vault.unlock/2

Then register it:

    Anemos.Runtime.register(:anemos, MyApp.Anemos.Secret)

> #### Wrap secret-bearing return values {: .warning}
>
> A verb that returns credential material should wrap it in
> `Anemos.Secret.new/2`. The wrapper redacts through `inspect/1`,
> string interpolation and `Logger`, which is what keeps a secret out of
> the application log when a policy does `log @token` or emits through
> the default channel connector. Nothing else on that path will redact
> it for you.

The module carries its own name — no string to fat-finger at the call site.

## Verb functions

Each verb function receives `(args, context)` where `args` is the list
of resolved arguments from the policy and `context` is the dispatch context
map. It should return `{:ok, result}` or `{:error, reason}`.

If your function takes a different arity, wrap it:

    verb :get_ip, fn args, _ctx -> MyApp.Infra.get_ip(hd(args)) end

# `verb`
*macro* 

Registers a verb handler.

The function should accept `(args :: list(), context :: map())`.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

# `Anemos.Runtime.Modules.Policy`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/policy.ex#L1)

`[POLICY::unload "id"]` — a policy that removes another.

Registered as `POLICY` in every `Anemos.Runtime`. This is the gated way
to unload: the rule that calls it came through `Anemos.Runtime.load/3`
and whatever authority stands there, so a signed policy can retire
another by name without `unload/2` needing an authority of its own
(A-81).

The unload is asked for, not done on the spot: the verb runs inside the
dispatcher, which is the process that has to do the removing. It is
carried out as soon as the dispatch that asked for it has finished.

# `__anemos_name__`

Returns the module name as registered in Anemos (e.g., `"SECRET"`).

# `__anemos_verbs__`

Returns the list of verb names this module handles.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

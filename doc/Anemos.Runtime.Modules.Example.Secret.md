# `Anemos.Runtime.Modules.Example.Secret`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/example.ex#L179)

`SECRET` double that deliberately yields nothing usable.

Every other double here answers plausibly, because a plausible answer
is what lets an example demonstrate its rule. This one must not: a
stub that returns something secret-shaped lets a policy run to
completion against fake credentials and report success. It returns a
self-describing marker instead, so the substitution is visible in the
output wherever the value lands.

# `__anemos_name__`

Returns the module name as registered in Anemos (e.g., `"SECRET"`).

# `__anemos_verbs__`

Returns the list of verb names this module handles.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

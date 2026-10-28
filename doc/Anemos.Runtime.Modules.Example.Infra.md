# `Anemos.Runtime.Modules.Example.Infra`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/modules/example.ex#L149)

`INFRA` double for `ddns.rule`.

`get_ip` reads addresses out of `:context_data` rather than querying an
interface, keyed `ip_<interface>_<type>` (for example
`--context-data ip_eth0_ipv4=203.0.113.7`). `ddns_update` echoes the
update it was handed; it contacts no provider.

# `__anemos_name__`

Returns the module name as registered in Anemos (e.g., `"SECRET"`).

# `__anemos_verbs__`

Returns the list of verb names this module handles.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

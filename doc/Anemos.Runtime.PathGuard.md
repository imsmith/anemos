# `Anemos.Runtime.PathGuard`
[🔗](https://github.com/imsmith/anemos/blob/main/lib/anemos/runtime/path_guard.ex#L1)

Confines a caller-supplied path to a configured root.

Policy text is untrusted, so every path that reaches a host filesystem
call arrived from an attacker-controlled string. `Comn.Repo.File.Local`
calls `File.open/2`, `File.stream!/1` and `File.rm/1` on whatever it is
given, with no normalization and no root — wire that to a real `FILE`
verb and `[FILE::read "../../etc/shadow"]` is a working traversal on day
one (A-11, C-4).

This module is the one place that decides whether a path is inside a
root, for the same reason `Anemos.Runtime.ContextScope` is the one place
that decides whether a context is inside another: two copies of a
boundary check are two chances to fix only one of them.

## Roots are named, not passed

Host modules name a root; the operator configures where it points:

    config :anemos, :path_roots, %{spool: "/var/lib/anemos/spool"}

A verb declares `path: :spool` in its `arg_schema/1` and the dispatcher
confines the argument before `handle_verb/3` is called. A module doing
its own filesystem work calls `confine/2` or `confine_root/2` directly.

## It fails closed

An unconfigured root is an `anemos.path/unknown_root` error, not "no root
declared, therefore allow". A verb that asked for confinement and did not
get it must not run — that is the whole point of asking.

## Segment comparison, not string prefix

`/srv/root` and `/srv/rootless` share a string prefix and share no
containment. The check appends a separator before comparing, so a sibling
directory whose name extends the root's cannot pass (the same defect
`ContextScope` was fixed for in A-06).

## What it does not defend against

Symlinks. `Path.expand/2` is lexical: it resolves `.` and `..` textually
and never touches the filesystem, so a symlink *inside* the root pointing
outside it still escapes. Closing that needs `:file.read_link_info/1` at
every level and is racy against a concurrent rename regardless. The
durable answer is a filesystem-level confinement (a bind mount, a
container, an unprivileged uid whose reachable set *is* the root); this
function stops the string-level traversal, which is the one a policy
author can perform without already having filesystem access.

# `confine`

```elixir
@spec confine(term(), String.t()) ::
  {:ok, String.t()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Expands `path` against `root` and asserts the result lies inside it.

Returns the expanded absolute path, which is what the caller should use
from then on — handing the unexpanded string onward would let the callee
re-resolve it differently and reopen the hole this just closed.

## Examples

    iex> Anemos.Runtime.PathGuard.confine("notes/a.txt", "/srv/data")
    {:ok, "/srv/data/notes/a.txt"}

    iex> {:error, error} = Anemos.Runtime.PathGuard.confine("../../etc/shadow", "/srv/data")
    iex> error.code
    "anemos.path/outside_root"

    iex> {:error, error} = Anemos.Runtime.PathGuard.confine("/etc/shadow", "/srv/data")
    iex> error.code
    "anemos.path/outside_root"

    iex> {:error, error} = Anemos.Runtime.PathGuard.confine("/srv/dataless/x", "/srv/data")
    iex> error.code
    "anemos.path/outside_root"

# `confine_root`

```elixir
@spec confine_root(term(), atom()) ::
  {:ok, String.t()} | {:error, Comn.Errors.ErrorStruct.t()}
```

Same as `confine/2`, but names a root from `config :anemos, :path_roots`.

An unconfigured root denies. See the moduledoc.

## Examples

    iex> {:error, error} = Anemos.Runtime.PathGuard.confine_root("a.txt", :nowhere)
    iex> {error.code, error.field}
    {"anemos.path/unknown_root", "nowhere"}

# `roots`

```elixir
@spec roots() :: %{optional(atom()) =&gt; String.t()}
```

Returns the configured root map.

---

*Consult [api-reference.md](api-reference.md) for complete listing*

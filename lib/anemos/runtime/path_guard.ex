defmodule Anemos.Runtime.PathGuard do
  @moduledoc """
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

  An unconfigured root is `{:error, {:unknown_root, name}}`, not "no root
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
  """

  @doc """
  Expands `path` against `root` and asserts the result lies inside it.

  Returns the expanded absolute path, which is what the caller should use
  from then on — handing the unexpanded string onward would let the callee
  re-resolve it differently and reopen the hole this just closed.

  ## Examples

      iex> Anemos.Runtime.PathGuard.confine("notes/a.txt", "/srv/data")
      {:ok, "/srv/data/notes/a.txt"}

      iex> Anemos.Runtime.PathGuard.confine("../../etc/shadow", "/srv/data")
      {:error, :outside_root}

      iex> Anemos.Runtime.PathGuard.confine("/etc/shadow", "/srv/data")
      {:error, :outside_root}

      iex> Anemos.Runtime.PathGuard.confine("/srv/dataless/x", "/srv/data")
      {:error, :outside_root}

  """
  @spec confine(term(), String.t()) :: {:ok, String.t()} | {:error, :outside_root | :not_a_path}
  def confine(path, root) when is_binary(path) and is_binary(root) do
    if printable_path?(path) do
      expanded_root = Path.expand(root)
      expanded = Path.expand(path, expanded_root)

      if expanded == expanded_root or String.starts_with?(expanded, expanded_root <> "/") do
        {:ok, expanded}
      else
        {:error, :outside_root}
      end
    else
      {:error, :not_a_path}
    end
  end

  def confine(_path, _root), do: {:error, :not_a_path}

  @doc """
  Same as `confine/2`, but names a root from `config :anemos, :path_roots`.

  An unconfigured root denies. See the moduledoc.

  ## Examples

      iex> Anemos.Runtime.PathGuard.confine_root("a.txt", :nowhere)
      {:error, {:unknown_root, :nowhere}}

  """
  @spec confine_root(term(), atom()) ::
          {:ok, String.t()} | {:error, :outside_root | :not_a_path | {:unknown_root, atom()}}
  def confine_root(path, root_name) when is_atom(root_name) do
    case Map.get(roots(), root_name) do
      root when is_binary(root) -> confine(path, root)
      _ -> {:error, {:unknown_root, root_name}}
    end
  end

  @doc """
  Returns the configured root map.
  """
  @spec roots() :: %{optional(atom()) => String.t()}
  def roots, do: Application.get_env(:anemos, :path_roots, %{})

  # A NUL byte truncates the path at the ERTS/libc boundary, so
  # "safe.txt\0../../etc/shadow" can pass a suffix check and open something
  # else. Reject anything that is not printable text outright.
  defp printable_path?(path), do: String.valid?(path) and not String.contains?(path, <<0>>)
end

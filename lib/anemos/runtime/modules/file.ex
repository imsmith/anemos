defmodule Anemos.Runtime.Modules.File do
  @moduledoc """
  Stub FILE module for development and testing.

  All verbs echo back their inputs as `%{module: "FILE", verb: verb, args: args}`.
  Replace with a real implementation for production use.

  ## Before you make this real

  The schemas below bound *shape* — the argument is a string, and it is not
  a megabyte long. That is all a stub can honestly claim, because a stub
  touches no filesystem.

  A real implementation must add `path: :some_root` to every path-taking
  verb and configure the root:

      config :anemos, :path_roots, %{files: "/var/lib/anemos/files"}

      def arg_schema("read"), do: [[type: :string, max_bytes: 4096, path: :files]]

  Without it, `[FILE::read "../../etc/shadow"]` is a working traversal the
  moment this module calls `File.read/1` — the host repo layer this would
  sit on does no normalization and no confinement of its own (A-11, C-4).
  `Anemos.Runtime.PathGuard` is the check; the schema is how you ask the
  dispatcher to apply it for you.
  """

  use Anemos.Module, name: "FILE"

  # 4 KiB is comfortably past PATH_MAX on every platform this runs on, and
  # bounds what a policy can make a host path routine allocate.
  @path_arg [type: :string, max_bytes: 4096]

  @doc false
  @impl Anemos.Runtime.Module
  def arg_schema("read"), do: [@path_arg]
  def arg_schema("write"), do: [@path_arg, [type: :any]]
  def arg_schema("rename"), do: [@path_arg, [type: :string, max_bytes: 4096, optional: true]]
  def arg_schema("extension"), do: [[type: :string, max_bytes: 4096, optional: true]]
  def arg_schema(_verb), do: nil

  verb :read, fn args, _ctx -> {:ok, %{module: "FILE", verb: "read", args: args}} end
  verb :write, fn args, _ctx -> {:ok, %{module: "FILE", verb: "write", args: args}} end
  verb :rename, fn args, _ctx -> {:ok, %{module: "FILE", verb: "rename", args: args}} end
  verb :extension, fn args, _ctx -> {:ok, %{module: "FILE", verb: "extension", args: args}} end
end

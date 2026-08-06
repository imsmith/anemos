defmodule Anemos.Runtime.Modules.Example do
  @moduledoc """
  Demonstration doubles for the module verbs used by `priv/examples/`.

  These exist for one reason: the shipped examples referenced `PDF`,
  `STRING`, `INFRA`, `SECRET` and `EVENT`, nothing registered them, and so
  two of the three examples could not run at all. They are doubles, not
  implementations — every verb here computes from its arguments and from
  the `:context_data` the caller supplied, and none of them opens a file,
  a socket, or a keystore.

  They are **not** registered by default. `Anemos.example_modules/0`
  returns them and `mix anemos.run --stub-modules` opts into them, because
  a `SECRET` handler that answers plausibly is precisely the thing that
  should never be ambient. `Example.Secret.unlock/2` therefore returns a
  self-identifying marker rather than anything secret-shaped: a rule that
  depends on real key material will visibly get a stub, not a value it can
  mistake for one.

  ## Supplying inputs

  Read verbs resolve against `:context_data` — the same map `?var` reads —
  so an example is driven entirely from the command line:

      mix anemos.run priv/examples/normalize-pdfs.rule \\
        --event FILE_CREATED --context /papers --stub-modules \\
        --context-data file=/papers/Draft_Report.pdf

  Write verbs echo the operation they *would* perform, as the shipped
  `DEVICE` and `FILE` stubs already do. An echo is the honest answer for a
  double: it reports the decision the rule reached without pretending the
  effect happened.
  """

  defmodule File do
    @moduledoc """
    `FILE` double that answers `extension` from the path under evaluation.

    Overrides `Anemos.Runtime.Modules.File`, which echoes every verb. That
    echo is what made `normalize-pdfs.rule`'s outer guard
    (`if [FILE::extension] eq "pdf"`) permanently false: a map never equals
    `"pdf"`. Here `extension` is real string computation over a path taken
    from the argument list or, when called with no arguments, from
    `context_data["file"]`.
    """

    use Anemos.Module, name: "FILE"

    verb(:extension, fn args, ctx -> {:ok, extension(args, ctx)} end)
    verb(:basename, fn args, ctx -> {:ok, Path.basename(path(args, ctx))} end)
    verb(:read, fn args, _ctx -> {:ok, %{module: "FILE", verb: "read", args: args}} end)
    verb(:write, fn args, _ctx -> {:ok, %{module: "FILE", verb: "write", args: args}} end)
    verb(:rename, fn args, _ctx -> {:ok, %{module: "FILE", verb: "rename", args: args}} end)

    @doc false
    def extension(args, ctx) do
      args
      |> path(ctx)
      |> Path.extname()
      |> String.trim_leading(".")
      |> String.downcase()
    end

    @doc false
    def path([path | _], _ctx) when is_binary(path), do: path
    def path(_args, ctx), do: Anemos.Runtime.Modules.Example.datum(ctx, "file", "")
  end

  defmodule Pdf do
    @moduledoc """
    `PDF` double distinguishing document content from stored metadata.

    `normalize-pdfs.rule` exists to demonstrate that the two can disagree,
    so this double keeps them in separate keys: `title` is the title the
    document *content* implies (defaulting to a human-readable form of the
    filename), while `metadata title` is what is *recorded*. Supply
    `--context-data meta_title=...` to make them differ and drive the
    example's inner branch.
    """

    use Anemos.Module, name: "PDF"

    alias Anemos.Runtime.Modules.Example

    verb(:title, fn _args, ctx -> {:ok, title(ctx)} end)
    verb(:author, fn _args, ctx -> {:ok, Example.datum(ctx, "author", "Unknown Author")} end)
    verb(:metadata, fn args, ctx -> {:ok, metadata(args, ctx)} end)

    # One argument reads a metadata field; two writes one. The write echoes,
    # since there is no document to record it in.
    defp metadata([key], ctx), do: Example.datum(ctx, "meta_#{key}", nil)
    defp metadata([key, value], _ctx), do: %{module: "PDF", verb: "metadata", args: [key, value]}
    defp metadata(args, _ctx), do: %{module: "PDF", verb: "metadata", args: args}

    defp title(ctx) do
      case Example.datum(ctx, "title", nil) do
        nil -> ctx |> Example.datum("file", "") |> derive_title()
        title -> title
      end
    end

    defp derive_title(""), do: "Untitled"

    defp derive_title(path) do
      path
      |> Path.basename(Path.extname(path))
      |> String.replace(["_", "-"], " ")
      |> String.trim()
    end
  end

  defmodule String do
    @moduledoc """
    `STRING` double. `slugify` is a genuine pure function, not a stand-in —
    there is nothing to fake about lowercasing and hyphenating a string.
    """

    use Anemos.Module, name: "STRING"

    verb(:slugify, fn args, _ctx -> {:ok, slugify(args)} end)

    verb(:downcase, fn args, _ctx -> {:ok, args |> first_string() |> Elixir.String.downcase()} end)

    @doc """
    Lowercases, strips anything that is not alphanumeric or a separator,
    and collapses separators into single hyphens.

    ## Examples

        iex> Anemos.Runtime.Modules.Example.String.slugify(["Draft Report (v2)"])
        "draft-report-v2"

        iex> Anemos.Runtime.Modules.Example.String.slugify([])
        ""
    """
    def slugify(args) do
      args
      |> first_string()
      |> Elixir.String.downcase()
      |> Elixir.String.replace(~r/[^a-z0-9]+/u, "-")
      |> Elixir.String.trim("-")
    end

    defp first_string([value | _]) when is_binary(value), do: value
    defp first_string([value | _]), do: inspect(value)
    defp first_string(_), do: ""
  end

  defmodule Infra do
    @moduledoc """
    `INFRA` double for `ddns.rule`.

    `get_ip` reads addresses out of `:context_data` rather than querying an
    interface, keyed `ip_<interface>_<type>` (for example
    `--context-data ip_eth0_ipv4=203.0.113.7`). `ddns_update` echoes the
    update it was handed; it contacts no provider.
    """

    use Anemos.Module, name: "INFRA"

    alias Anemos.Runtime.Modules.Example

    verb(:get_ip, fn args, ctx -> {:ok, get_ip(args, ctx)} end)

    verb(:ddns_update, fn args, _ctx ->
      {:ok, %{module: "INFRA", verb: "ddns_update", args: args}}
    end)

    # `[INFRA::get_ip "eth0" type:ipv4]` does NOT arrive as a keyword pair.
    # The parser flattens `type:ipv4` into two positional arguments — the
    # identifier "type" followed by the atom "ipv4" — so a handler cannot
    # distinguish it from two positional strings. Reading the element after
    # "type" is the only interpretation available; it is a workaround for
    # that flattening, not the shape a keyword argument should have.
    defp get_ip(args, ctx) do
      interface = Enum.at(args, 0, "eth0")
      type = keyword_after(args, "type", "ipv4")

      Example.datum(ctx, "ip_#{interface}_#{type}", nil)
    end

    defp keyword_after(args, key, default) do
      case Enum.find_index(args, &(&1 == key)) do
        nil -> default
        index -> Enum.at(args, index + 1, default)
      end
    end
  end

  defmodule Secret do
    @moduledoc """
    `SECRET` double that deliberately yields nothing usable.

    Every other double here answers plausibly, because a plausible answer
    is what lets an example demonstrate its rule. This one must not: a
    stub that returns something secret-shaped lets a policy run to
    completion against fake credentials and report success. It returns a
    self-describing marker instead, so the substitution is visible in the
    output wherever the value lands.
    """

    use Anemos.Module, name: "SECRET"

    verb(:unlock, fn args, _ctx -> {:ok, marker("unlock", args)} end)
    verb(:rotate, fn args, _ctx -> {:ok, marker("rotate", args)} end)

    defp marker(verb, args) do
      %{
        module: "SECRET",
        verb: verb,
        args: args,
        stub: "no secret material — Anemos.Runtime.Modules.Example.Secret"
      }
    end
  end

  defmodule Event do
    @moduledoc """
    `EVENT` double. Verb names are dotted event names (`ip.addr.changed`),
    so `handle_verb/3` accepts any verb and echoes it rather than
    enumerating a fixed list.
    """

    @behaviour Anemos.Runtime.Module
    @behaviour Comn

    @impl Anemos.Runtime.Module
    def handle_verb(verb, args, _context) do
      {:ok, %{module: "EVENT", verb: verb, args: args}}
    end

    @doc false
    def __anemos_name__, do: "EVENT"

    @impl Comn
    def look, do: "EVENT — example double; echoes any dotted event name"

    @impl Comn
    def recon, do: %{type: :implementation, anemos_name: "EVENT", verbs: :any}

    @impl Comn
    def choices, do: %{verbs: ["<any dotted event name>"]}

    @impl Comn
    def act(%{verb: verb, args: args, context: ctx}), do: handle_verb(verb, args, ctx)
    def act(%{verb: verb, args: args}), do: handle_verb(verb, args, %{})
    def act(_input), do: {:error, :unknown_action}
  end

  @doc """
  Reads one key from the dispatch context's `:context_data`, or `default`.

  ## Examples

      iex> Anemos.Runtime.Modules.Example.datum(%{context_data: %{"file" => "a.pdf"}}, "file", "")
      "a.pdf"

      iex> Anemos.Runtime.Modules.Example.datum(%{}, "file", "none")
      "none"
  """
  @spec datum(map(), Elixir.String.t(), term()) :: term()
  def datum(context, key, default) do
    case get_in(context, [:context_data, key]) do
      nil -> default
      value -> value
    end
  end
end

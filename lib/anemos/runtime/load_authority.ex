defmodule Anemos.Runtime.LoadRequest do
  @moduledoc """
  Everything an `Anemos.Runtime.LoadAuthority` gets to decide on.

  Deliberately a closed struct rather than a bare map: an authority is a
  security decision point, and a decision point that pattern-matches on a
  map is one field rename away from matching nothing and — depending on how
  it was written — failing open.

  `signers` is the seam for A-05. `signed_by` is parsed today and verified
  by nothing; when verification lands, it is an authority implementation
  that checks these names against a keyring, and neither this struct nor
  `Anemos.Runtime.load/3` has to change.
  """

  @enforce_keys [:runtime, :source, :byte_size, :authorization, :signers]
  defstruct [:runtime, :source, :byte_size, :authorization, :signers]

  @type t :: %__MODULE__{
          runtime: atom(),
          source: String.t(),
          byte_size: non_neg_integer(),
          authorization: term(),
          signers: [atom() | String.t()]
        }
end

defmodule Anemos.Runtime.LoadAuthority do
  @moduledoc """
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
     `Anemos.Runtime.act/1` used to accept `%{action: :load, ...}`, so
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
  `Anemos.Runtime.recon/0` both report it — rather than an absence nobody
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

  ## Where A-05 slots in

  `authorize/1` runs *after* the source is parsed, which is the only reason
  `LoadRequest.signers` can be populated at all. Signature verification is
  therefore an authority implementation — it needs the signer names, the
  source bytes to verify against, and a keyring, and it has all three. No
  change to `load/3`, to `LoadRequest`, or to this behaviour is required
  when it lands.
  """

  alias Anemos.Runtime.LoadRequest

  # 1 MiB. A policy source is human-authored text; the largest example in
  # priv/ is under 2 KiB. This is three orders of magnitude of headroom and
  # still bounds what an untrusted caller can make the parser allocate.
  @default_max_bytes 1_048_576

  @typedoc """
  An authority's verdict.

  `:ok` permits the load. `{:error, reason}` refuses it; `reason` is logged
  and named in the caller's error, so it must not carry a credential.
  """
  @type verdict :: :ok | {:error, atom() | String.t()}

  @doc "Decides whether `request` may be installed into the runtime. Refuse by default."
  @callback authorize(request :: LoadRequest.t()) :: verdict()

  defmodule Permissive do
    @moduledoc """
    The default authority: grants every load.

    Preserves the pre-A-12 contract for embedders that have not configured
    anything. Replace it before accepting policy from anyone you would not
    hand a shell to.
    """

    @behaviour Anemos.Runtime.LoadAuthority

    @impl true
    def authorize(_request), do: :ok
  end

  defmodule Denied do
    @moduledoc """
    Refuses every load.

    For a runtime whose policy set is installed once at boot through a
    privileged path and must never change afterwards.
    """

    @behaviour Anemos.Runtime.LoadAuthority

    @impl true
    def authorize(_request), do: {:error, :loading_disabled}
  end

  @doc """
  Returns the configured authority module.

  ## Examples

      iex> Anemos.Runtime.LoadAuthority.configured()
      Anemos.Runtime.LoadAuthority.Permissive

  """
  @spec configured() :: module()
  def configured, do: Application.get_env(:anemos, :load_authority, Permissive)

  @doc """
  Returns the configured source-size ceiling in bytes.
  """
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: Application.get_env(:anemos, :max_policy_bytes, @default_max_bytes)

  @doc """
  Enforces the ceiling. Runs before the source is parsed and regardless of
  the authority.
  """
  @spec check_size(String.t()) :: :ok | {:error, String.t()}
  def check_size(source) when is_binary(source) do
    size = byte_size(source)
    limit = max_bytes()

    if size <= limit do
      :ok
    else
      {:error, "policy source is #{size} bytes, over the #{limit} byte ceiling"}
    end
  end

  @doc """
  Asks the configured authority to authorize `request`.
  """
  @spec authorize(LoadRequest.t()) :: verdict()
  def authorize(%LoadRequest{} = request), do: configured().authorize(request)

  @doc """
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

  """
  @spec gate(atom(), String.t(), keyword()) ::
          {:ok, Anemos.AST.Program.t()} | {:error, Comn.Errors.ErrorStruct.t() | String.t()}
  def gate(runtime, source, opts \\ []) when is_binary(source) do
    with :ok <- gate_size(source),
         {:ok, ast} <- Anemos.Parser.parse(source),
         :ok <- gate_authority(runtime, source, ast, opts) do
      {:ok, ast}
    end
  end

  defp gate_size(source) do
    case check_size(source) do
      :ok -> :ok
      {:error, message} -> {:error, load_denied(message)}
    end
  end

  defp gate_authority(runtime, source, ast, opts) do
    request = %LoadRequest{
      runtime: runtime,
      source: source,
      byte_size: byte_size(source),
      authorization: Keyword.get(opts, :authorization),
      signers: signers(ast)
    }

    case authorize(request) do
      :ok ->
        :ok

      {:error, reason} ->
        # The authority's reason names *why* it refused, not what it was
        # given, so it is safe to surface. The source is not.
        #
        # The module is named in full rather than left bare: this string
        # reaches a policy author through `mix anemos.run`, and a bare
        # module name in that position does not tell them what refused
        # them or what to change. An operator reading a log can still
        # identify the module.
        {:error,
         load_denied(
           "the configured load authority #{inspect(configured())} " <>
             "refused the load: #{inspect(reason)}"
         )}
    end
  end

  defp load_denied(message) do
    Comn.Errors.Registry.error!("anemos.runtime/load_denied", field: "source", message: message)
  end

  @doc """
  Collects the `signed_by` names declared by an AST's rules.

  Empty when nothing in the source claims a signer, which is itself a fact
  an authority may want to refuse on.
  """
  @spec signers(Anemos.AST.Program.t() | term()) :: [atom() | String.t()]
  def signers(%Anemos.AST.Program{declarations: declarations}) do
    declarations
    |> Enum.flat_map(fn
      %{meta: meta} when is_map(meta) -> List.wrap(Map.get(meta, :signed_by))
      _other -> []
    end)
    |> Enum.uniq()
  end

  def signers(_ast), do: []
end

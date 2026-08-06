defmodule Anemos.Runtime.TrustStore do
  @moduledoc """
  Per-runtime trust configuration: a keyring of **public** verification
  keys, and the policy for sources that declare no signer at all (A-05).

  One of these is started for every `Anemos.Runtime`, whether or not the
  embedder configures anything. That is deliberate: a runtime that has no
  trust store is a runtime `Anemos.Runtime.LoadAuthority.Signed` cannot
  make a decision about, and the only safe answer to "I cannot decide" on
  a security boundary is refusal. Always starting one means refusal is
  reserved for genuine failures rather than being the normal case.

  ## Public keys only, and it is enforced here

  A key handed to this store must have `private: nil`. This is not
  hygiene, it is the invariant the whole design rests on: `comn` finding
  C-3 records that the Ed25519 *signing* private key is currently reused
  as ChaCha20 encryption key material, a key-separation violation. A
  verifier that never holds a private key cannot compound that mistake,
  and cannot be quietly extended into a signer later. Anemos verifies;
  something else signs.

  A key carrying private material is therefore refused — loudly, at
  ingest, by `start_link/1` raising and by `put_key/3` answering
  `{:error, :private_key_material}` — rather than accepted and ignored.

  ## What this store does *not* decide

  Which algorithms are acceptable. A `Comn.Secrets.Key` may declare
  `:rsa_4096` or `:ecdsa_p256`, and this store will hold one; it is
  `Signed` that refuses to verify against it, explicitly, on the load
  path. The split is intentional — refusing private material protects an
  invariant of *the store*, whereas which signatures count is *the
  verifier's* policy, and putting it here would hide the refusal from the
  load that triggered it.

  ## Signer names are strings

  `signed_by :operator` reaches an authority as the **string**
  `"operator"`, not the atom `:operator` — the lexer's atom token payload
  is a binary and `Anemos.Parser` passes it straight through. A keyring
  keyed on atoms would therefore never match, and a verifier that never
  matches a signer is one that never rejects one: fail-open, on the
  boundary itself. Every name entering this store is normalised to a
  binary so that either spelling in configuration behaves identically.

  ## Options

    * `:name` — process registration name.
    * `:keyring` — `%{signer_name => Comn.Secrets.Key.t()}`. Names may be
      atoms or strings; they are stored as strings. Defaults to empty,
      which means every declared signer is unknown, which means refused.
    * `:unsigned_policy` — `:strict | :warn | :permit`, default
      `:permit`. See `unsigned_policy/1`.
  """

  use Agent

  alias Comn.Secrets.Key

  @policies [:strict, :warn, :permit]

  # Knowingly the insecure default. Every example in `priv/`, every test
  # fixture and every Livebook cell is currently unsigned, and there is no
  # signing tooling in or around this repository yet, so `:strict` by
  # default would make the CLI unusable before anyone could produce a
  # signature to satisfy it. `:permit` allows incremental adoption.
  #
  # REVISIT once signing tooling exists. A permissive default that outlives
  # its justification is exactly how A-05 happened in the first place: the
  # keyword shipped ahead of the mechanism and nothing forced the two back
  # together.
  @default_policy :permit

  @typedoc "What to do with a source that names no signer at all."
  @type unsigned_policy :: :strict | :warn | :permit

  @typedoc "Signer name to public key. Names are always binaries."
  @type keyring :: %{optional(String.t()) => Key.t()}

  @doc """
  Starts a trust store.

  Raises `ArgumentError` on a keyring entry carrying private key material
  or on an unrecognised `:unsigned_policy`. Both are configuration
  mistakes on a security boundary, and a boundary that silently corrects
  its own configuration is not one.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts \\ []) do
    keyring = opts |> Keyword.get(:keyring, %{}) |> normalize_keyring!()
    policy = opts |> Keyword.get(:unsigned_policy, @default_policy) |> validate_policy!()

    Agent.start_link(
      fn -> %{keyring: keyring, unsigned_policy: policy} end,
      name: Keyword.get(opts, :name)
    )
  end

  @doc """
  The registered name of the trust store belonging to `runtime`.
  """
  @spec name_for(atom()) :: atom()
  def name_for(runtime), do: :"#{runtime}.trust_store"

  @doc """
  Returns the whole trust configuration for `runtime`.

  `{:error, :no_trust_store}` when the runtime has none — which a caller
  on the load path must treat as a refusal, not as an absence of policy.
  """
  @spec fetch(atom()) :: {:ok, %{keyring: keyring(), unsigned_policy: unsigned_policy()}} | {:error, :no_trust_store}
  def fetch(runtime) do
    case Process.whereis(name_for(runtime)) do
      nil -> {:error, :no_trust_store}
      pid -> {:ok, Agent.get(pid, & &1)}
    end
  end

  @doc """
  Looks up the public key trusted for `signer` in `runtime`.

  `signer` may be an atom or a string; both resolve to the same entry.
  `:error` means the signer is unknown, and an unknown signer is refused
  rather than permitted — under multi-tenancy, a name nobody has vouched
  for is a name with no authority behind it.
  """
  @spec key(atom(), atom() | String.t()) :: {:ok, Key.t()} | :error
  def key(runtime, signer) do
    with {:ok, %{keyring: keyring}} <- fetch(runtime) do
      Map.fetch(keyring, to_string(signer))
    else
      {:error, :no_trust_store} -> :error
    end
  end

  @doc """
  Returns the unsigned-rule policy in force for `runtime`.

    * `:strict` — refuse a source that declares no signer.
    * `:warn` — admit it, and log that it was admitted unverified.
    * `:permit` — admit it silently. The default; see the module note.

  A runtime with no trust store reports the default, because this is a
  question about *policy* rather than a decision about a load; the load
  path itself fails closed via `fetch/1`.
  """
  @spec unsigned_policy(atom()) :: unsigned_policy()
  def unsigned_policy(runtime) do
    case fetch(runtime) do
      {:ok, %{unsigned_policy: policy}} -> policy
      {:error, :no_trust_store} -> @default_policy
    end
  end

  @doc """
  Adds or replaces the public key trusted for `signer`. Supports rotation
  without restarting the runtime.

  Answers `{:error, :private_key_material}` rather than raising, because
  unlike `start_link/1` this runs against a live system and a rejected
  rotation should not take the runtime down with it. The old key stays in
  force, which is the fail-safe outcome.
  """
  @spec put_key(atom(), atom() | String.t(), Key.t()) ::
          :ok | {:error, :private_key_material | :no_trust_store}
  def put_key(runtime, signer, %Key{} = key) do
    cond do
      not is_nil(key.private) ->
        {:error, :private_key_material}

      is_nil(Process.whereis(name_for(runtime))) ->
        {:error, :no_trust_store}

      true ->
        Agent.update(name_for(runtime), fn state ->
          %{state | keyring: Map.put(state.keyring, to_string(signer), key)}
        end)
    end
  end

  @doc """
  Removes the key trusted for `signer`. Revocation.
  """
  @spec delete_key(atom(), atom() | String.t()) :: :ok | {:error, :no_trust_store}
  def delete_key(runtime, signer) do
    case Process.whereis(name_for(runtime)) do
      nil ->
        {:error, :no_trust_store}

      pid ->
        Agent.update(pid, fn state ->
          %{state | keyring: Map.delete(state.keyring, to_string(signer))}
        end)
    end
  end

  # --- Validation ---

  defp normalize_keyring!(keyring) when is_map(keyring) do
    Map.new(keyring, fn {signer, key} -> {to_string(signer), validate_key!(signer, key)} end)
  end

  defp normalize_keyring!(other) do
    raise ArgumentError, ":keyring must be a map of signer name to Comn.Secrets.Key, got: #{inspect(other)}"
  end

  defp validate_key!(_signer, %Key{private: nil} = key), do: key

  defp validate_key!(signer, %Key{}) do
    raise ArgumentError,
          "the key for signer #{inspect(signer)} carries private material; " <>
            "Anemos holds public key material only and never signs (see the module doc, and comn finding C-3)"
  end

  defp validate_key!(signer, other) do
    raise ArgumentError,
          "the keyring entry for signer #{inspect(signer)} is not a Comn.Secrets.Key: #{inspect(other)}"
  end

  defp validate_policy!(policy) when policy in @policies, do: policy

  defp validate_policy!(other) do
    raise ArgumentError,
          ":unsigned_policy must be one of #{inspect(@policies)}, got: #{inspect(other)}"
  end
end

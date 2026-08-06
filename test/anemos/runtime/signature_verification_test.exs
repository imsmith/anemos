defmodule Anemos.Runtime.SignatureVerificationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-05 — `signed_by` is parsed and never verified.

  A rule reading `signed_by :operator` looks authenticated to every human
  and every tool that inspects it, and until this landed it was accepted
  identically to an unsigned one. These tests pin the shape of the fix: a
  detached Ed25519 signature, a public-key-only keyring, all declared
  signers required, and every failure mode refusing rather than passing.
  """

  import ExUnit.CaptureLog

  alias Anemos.Runtime.LoadAuthority
  alias Anemos.Runtime.LoadAuthority.Signed
  alias Anemos.Runtime.TrustStore
  alias Comn.Secrets.Key

  # Signing is out of scope for this repository — Anemos verifies, something
  # else signs. This exists only to manufacture a fixture, which is why it
  # lives in the test file and not in `lib/`.
  defp keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {%Key{algorithm: :ed25519, public: public}, private}
  end

  defp sign(source, private), do: :crypto.sign(:eddsa, :none, source, [private, :ed25519])

  @signed_source """
  rule watched {
    signed_by :operator
    when EV { log "ok" }
  }
  """

  @unsigned_source """
  rule plain {
    when EV { log "ok" }
  }
  """

  @two_signers """
  rule first {
    signed_by :operator
    when EV { log "one" }
  }

  rule second {
    signed_by :auditor
    when EV { log "two" }
  }
  """

  setup do
    on_exit(fn -> Application.delete_env(:anemos, :load_authority) end)
    Application.put_env(:anemos, :load_authority, Signed)
    :ok
  end

  describe "a valid detached signature" do
    test "is accepted and the policy is installed" do
      {key, private} = keypair()

      start_supervised!(
        {Anemos.Runtime, name: :sv_ok, keyring: %{"operator" => key}, unsigned_policy: :strict}
      )

      sig = sign(@signed_source, private)

      assert :ok =
               Anemos.Runtime.load(:sv_ok, @signed_source,
                 authorization: %{signatures: %{"operator" => sig}}
               )

      assert {:ok, [_ | _]} = Anemos.Runtime.dispatch(:sv_ok, "EV")
    end

    test "is accepted when carried Base64-encoded, as a transport would carry it" do
      {key, private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_b64, keyring: %{"operator" => key}})

      sig = @signed_source |> sign(private) |> Base.encode64()

      assert :ok =
               Anemos.Runtime.load(:sv_b64, @signed_source,
                 authorization: %{signatures: %{"operator" => sig}}
               )
    end

    test "the single-signature shorthand resolves to the sole declared signer" do
      {key, private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_one, keyring: %{"operator" => key}})

      assert :ok =
               Anemos.Runtime.load(:sv_one, @signed_source,
                 authorization: %{signature: sign(@signed_source, private)}
               )
    end
  end

  describe "verification failures" do
    test "a tampered source is rejected and nothing is installed" do
      {key, private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_tamper, keyring: %{"operator" => key}})

      sig = sign(@signed_source, private)
      tampered = String.replace(@signed_source, ~s("ok"), ~s("pwned"))
      refute tampered == @signed_source

      assert {:error, err} =
               Anemos.Runtime.load(:sv_tamper, tampered,
                 authorization: %{signatures: %{"operator" => sig}}
               )

      assert err.code == "anemos.runtime/load_denied"
      assert {:ok, []} = Anemos.Runtime.dispatch(:sv_tamper, "EV")
    end

    test "a signature from the wrong key is rejected" do
      {key, _operator_private} = keypair()
      {_other_key, attacker_private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_wrongkey, keyring: %{"operator" => key}})

      assert {:error, err} =
               Anemos.Runtime.load(:sv_wrongkey, @signed_source,
                 authorization: %{signatures: %{"operator" => sign(@signed_source, attacker_private)}}
               )

      assert err.code == "anemos.runtime/load_denied"

      assert {:error, {:bad_signature, "operator"}} =
               Signed.decide(request(:sv_wrongkey, @signed_source, %{
                 signatures: %{"operator" => sign(@signed_source, attacker_private)}
               }))
    end

    test "a signer the keyring does not know is rejected, not permitted" do
      {key, private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_unknown, keyring: %{"somebody-else" => key}})

      assert {:error, err} =
               Anemos.Runtime.load(:sv_unknown, @signed_source,
                 authorization: %{signatures: %{"operator" => sign(@signed_source, private)}}
               )

      assert err.code == "anemos.runtime/load_denied"

      assert {:error, {:unknown_signer, "operator"}} =
               Signed.decide(request(:sv_unknown, @signed_source, %{signatures: %{}}))
    end

    test "a declared signer with no signature supplied is rejected" do
      {key, _private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_nosig, keyring: %{"operator" => key}})

      assert {:error, err} = Anemos.Runtime.load(:sv_nosig, @signed_source)
      assert err.code == "anemos.runtime/load_denied"

      assert {:error, {:missing_signature, "operator"}} =
               Signed.decide(request(:sv_nosig, @signed_source, nil))
    end

    test "a runtime with no trust store fails closed rather than open" do
      # `Signed` cannot verify what it has no keyring for. The only safe
      # answer is refusal; the tempting one is `:ok`.
      assert {:error, {:no_trust_store, :sv_absent}} =
               Signed.decide(request(:sv_absent, @signed_source, %{signatures: %{}}))
    end
  end

  describe "key algorithms" do
    test "a non-Ed25519 key is refused explicitly, not silently passed" do
      rsa = %Key{algorithm: :rsa_4096, public: :crypto.strong_rand_bytes(512)}

      start_supervised!({Anemos.Runtime, name: :sv_rsa, keyring: %{"operator" => rsa}})

      assert {:error, err} =
               Anemos.Runtime.load(:sv_rsa, @signed_source,
                 authorization: %{signatures: %{"operator" => :crypto.strong_rand_bytes(64)}}
               )

      assert err.code == "anemos.runtime/load_denied"

      assert {:error, {:unsupported_algorithm, "operator", :rsa_4096}} =
               Signed.decide(
                 request(:sv_rsa, @signed_source, %{
                   signatures: %{"operator" => :crypto.strong_rand_bytes(64)}
                 })
               )
    end

    test "a keyring entry carrying private material is refused at ingest" do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      loaded = %Key{algorithm: :ed25519, public: public, private: private}

      assert_raise ArgumentError, ~r/public key/, fn ->
        TrustStore.start_link(name: :sv_priv_store, keyring: %{"operator" => loaded})
      end
    end
  end

  describe "the string-versus-atom trap" do
    # `parser.ex:163` matches `{:atom, _, signer}`, but the lexer's atom
    # token payload is a binary. `signed_by :operator` therefore yields
    # `signers: ["operator"]`. A keyring keyed on atoms silently never
    # matches, and a verifier that never matches a signer is one that never
    # rejects one — fail-open, on the security boundary itself.
    test "the parser really does hand the authority strings, not atoms" do
      {:ok, ast} = Anemos.Parser.parse(@signed_source)
      assert LoadAuthority.signers(ast) == ["operator"]
      refute :operator in LoadAuthority.signers(ast)
    end

    test "a keyring configured with atom keys still matches a string signer" do
      {key, private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_atomring, keyring: %{operator: key}})

      assert :ok =
               Anemos.Runtime.load(:sv_atomring, @signed_source,
                 authorization: %{signatures: %{operator: sign(@signed_source, private)}}
               )
    end

    test "an atom-keyed keyring does not accidentally admit an unrelated signer" do
      {key, private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_atomring2, keyring: %{auditor: key}})

      assert {:error, _} =
               Anemos.Runtime.load(:sv_atomring2, @signed_source,
                 authorization: %{signatures: %{"operator" => sign(@signed_source, private)}}
               )
    end
  end

  describe "multiple signers — conjunctive" do
    test "every declared signer must verify" do
      {op_key, op_priv} = keypair()
      {au_key, au_priv} = keypair()

      start_supervised!(
        {Anemos.Runtime, name: :sv_both, keyring: %{"operator" => op_key, "auditor" => au_key}}
      )

      assert :ok =
               Anemos.Runtime.load(:sv_both, @two_signers,
                 authorization: %{
                   signatures: %{
                     "operator" => sign(@two_signers, op_priv),
                     "auditor" => sign(@two_signers, au_priv)
                   }
                 }
               )
    end

    test "one good signature does not carry a source that names two signers" do
      {op_key, op_priv} = keypair()
      {au_key, _au_priv} = keypair()

      start_supervised!(
        {Anemos.Runtime, name: :sv_half, keyring: %{"operator" => op_key, "auditor" => au_key}}
      )

      assert {:error, err} =
               Anemos.Runtime.load(:sv_half, @two_signers,
                 authorization: %{signatures: %{"operator" => sign(@two_signers, op_priv)}}
               )

      assert err.code == "anemos.runtime/load_denied"
      assert {:ok, []} = Anemos.Runtime.dispatch(:sv_half, "EV")
    end
  end

  describe "the unsigned-rule policy" do
    test ":permit admits a source that declares no signer" do
      start_supervised!({Anemos.Runtime, name: :sv_permit, unsigned_policy: :permit})
      assert :ok = Anemos.Runtime.load(:sv_permit, @unsigned_source)
    end

    test ":permit is the default, knowingly" do
      start_supervised!({Anemos.Runtime, name: :sv_default})
      assert TrustStore.unsigned_policy(:sv_default) == :permit
      assert :ok = Anemos.Runtime.load(:sv_default, @unsigned_source)
    end

    test ":warn admits it and says so" do
      start_supervised!({Anemos.Runtime, name: :sv_warn, unsigned_policy: :warn})

      log =
        capture_log(fn ->
          assert :ok = Anemos.Runtime.load(:sv_warn, @unsigned_source)
        end)

      assert log =~ "unsigned"
    end

    test ":strict refuses it and installs nothing" do
      start_supervised!({Anemos.Runtime, name: :sv_strict, unsigned_policy: :strict})

      assert {:error, err} = Anemos.Runtime.load(:sv_strict, @unsigned_source)
      assert err.code == "anemos.runtime/load_denied"
      assert {:ok, []} = Anemos.Runtime.dispatch(:sv_strict, "EV")
    end

    test "the policy applies only to sources declaring no signer at all" do
      # A source that names a signer is never merely "unsigned" — it is
      # making a provenance claim, and :permit must not launder it.
      {key, _private} = keypair()

      start_supervised!(
        {Anemos.Runtime, name: :sv_claim, keyring: %{"operator" => key}, unsigned_policy: :permit}
      )

      assert {:error, err} = Anemos.Runtime.load(:sv_claim, @signed_source)
      assert err.code == "anemos.runtime/load_denied"
    end

    test "a source of non-rule declarations cannot be signed at all — a known limitation" do
      # `signed_by` is rule-only syntax (`parser.ex:154-178` is reached
      # from `parse_rule` alone), so a source made of conditions,
      # capabilities or data blocks declares no signer and *cannot*. Under
      # `:permit` that means it loads unverified; under `:strict` it means
      # it can never load. Pinned here so the limitation is a decision on
      # the record rather than a surprise in production.
      conditions_only = """
      condition night {
        when EV { log "x" }
      }
      """

      assert {:error, _} = Anemos.Parser.parse("""
             condition night {
               signed_by :operator
               when EV { log "x" }
             }
             """)

      start_supervised!({Anemos.Runtime, name: :sv_cond, unsigned_policy: :strict})
      assert {:error, err} = Anemos.Runtime.load(:sv_cond, conditions_only)
      assert err.code == "anemos.runtime/load_denied"
    end

    test "an unrecognised policy mode is refused at start rather than defaulted" do
      assert_raise ArgumentError, ~r/unsigned_policy/, fn ->
        TrustStore.start_link(name: :sv_bad_mode_store, unsigned_policy: :whatever)
      end
    end
  end

  describe "runtime key management" do
    test "a key can be added to a live runtime, and rotation takes effect" do
      {key, private} = keypair()

      start_supervised!({Anemos.Runtime, name: :sv_rotate})

      assert {:error, _} =
               Anemos.Runtime.load(:sv_rotate, @signed_source,
                 authorization: %{signatures: %{"operator" => sign(@signed_source, private)}}
               )

      assert :ok = TrustStore.put_key(:sv_rotate, "operator", key)

      assert :ok =
               Anemos.Runtime.load(:sv_rotate, @signed_source,
                 authorization: %{signatures: %{"operator" => sign(@signed_source, private)}}
               )
    end

    test "put_key refuses private material too" do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      start_supervised!({Anemos.Runtime, name: :sv_putpriv})

      assert {:error, :private_key_material} =
               TrustStore.put_key(:sv_putpriv, "operator", %Key{
                 algorithm: :ed25519,
                 public: public,
                 private: private
               })
    end
  end

  defp request(runtime, source, authorization) do
    {:ok, ast} = Anemos.Parser.parse(source)

    %Anemos.Runtime.LoadRequest{
      runtime: runtime,
      source: source,
      byte_size: byte_size(source),
      authorization: authorization,
      signers: LoadAuthority.signers(ast)
    }
  end
end

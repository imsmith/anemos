defmodule Anemos.Runtime.SourceLevelSignedByTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-60 — `signed_by` was rule-only syntax, so `:strict` could not load a
  conditions-only source.

  `parse_rule_metadata/2` was reachable from `parse_rule/1` alone, so a source
  made of conditions, capabilities or data blocks declared no signer and had no
  syntax by which it could. Under `:permit` such a source loaded unverified;
  under `:strict` it could never load at all — which made `:strict`, the whole
  point of the setting, unusable for any policy set containing a standalone
  condition file. Since condition bodies execute side effects, such a file is a
  full payload, so scoping `:strict` to rule-bearing sources was not available.

  `signed_by` is now a source-level declaration. The signature covers the whole
  source either way, so this is also the placement that tells the truth about
  what is being claimed.
  """

  import ExUnit.CaptureLog

  alias Anemos.AST
  alias Anemos.Runtime.LoadAuthority
  alias Anemos.Runtime.LoadAuthority.Signed
  alias Comn.Secrets.Key

  defp keypair do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {%Key{algorithm: :ed25519, public: public}, private}
  end

  defp sign(source, private), do: :crypto.sign(:eddsa, :none, source, [private, :ed25519])

  @conditions_only """
  signed_by :operator

  condition night {
    when EV { log "x" }
  }
  """

  setup do
    on_exit(fn -> Application.delete_env(:anemos, :load_authority) end)
    Application.put_env(:anemos, :load_authority, Signed)
    :ok
  end

  describe "parsing" do
    test "a source-level signed_by parses into its own declaration" do
      assert {:ok, %AST.Program{declarations: declarations}} =
               Anemos.Parser.parse(@conditions_only)

      assert %AST.SignedBy{signer: "operator"} =
               Enum.find(declarations, &match?(%AST.SignedBy{}, &1))
    end

    test "it may precede a rule as well as a condition" do
      assert {:ok, %AST.Program{declarations: declarations}} =
               Anemos.Parser.parse("""
               signed_by :operator

               rule r {
                 when EV { log "x" }
               }
               """)

      assert Enum.any?(declarations, &match?(%AST.SignedBy{signer: "operator"}, &1))
      assert Enum.any?(declarations, &match?(%AST.Rule{}, &1))
    end

    test "several source-level signers are all declared" do
      assert {:ok, %AST.Program{declarations: declarations}} =
               Anemos.Parser.parse("""
               signed_by :operator
               signed_by :auditor

               condition night {
                 when EV { log "x" }
               }
               """)

      signers = for %AST.SignedBy{signer: s} <- declarations, do: s
      assert Enum.sort(signers) == ["auditor", "operator"]
    end

    test "signed_by without a signer name is a positioned parse error" do
      assert {:error, message} =
               Anemos.Parser.parse("""
               signed_by

               condition night {
                 when EV { log "x" }
               }
               """)

      assert message =~ "line 1"
    end

    # `parse_declarations/2` treats a failed declaration as "end of parseable
    # declarations" once anything has parsed, so the obvious worry is that a
    # malformed trailing `signed_by` gets silently dropped and the source loads
    # as unsigned. Probed, and it does not: the leftover tokens are refused.
    # Pinned because the failure mode would be invisible.
    test "a malformed signed_by after a valid declaration is refused, not dropped" do
      assert {:error, _} =
               Anemos.Parser.parse("""
               condition night {
                 when EV { log "x" }
               }

               signed_by
               """)
    end

    test "a well-formed signed_by after a declaration is still collected" do
      {:ok, ast} =
        Anemos.Parser.parse("""
        condition night {
          when EV { log "x" }
        }

        signed_by :operator
        """)

      assert LoadAuthority.signers(ast) == ["operator"]
    end
  end

  describe "signer collection" do
    test "a conditions-only source now declares a signer" do
      {:ok, ast} = Anemos.Parser.parse(@conditions_only)

      assert LoadAuthority.signers(ast) == ["operator"]
    end

    test "source-level and rule-level signers are unioned, and both are required" do
      {:ok, ast} =
        Anemos.Parser.parse("""
        signed_by :operator

        rule r {
          signed_by :auditor
          when EV { log "x" }
        }
        """)

      assert Enum.sort(LoadAuthority.signers(ast)) == ["auditor", "operator"]
    end

    test "the same name declared at both levels is counted once" do
      {:ok, ast} =
        Anemos.Parser.parse("""
        signed_by :operator

        rule r {
          signed_by :operator
          when EV { log "x" }
        }
        """)

      assert LoadAuthority.signers(ast) == ["operator"]
    end
  end

  describe "compilation" do
    test "the declaration is not a runtime construct and compiles to nothing" do
      {:ok, ast} = Anemos.Parser.parse(@conditions_only)
      {:ok, result} = Anemos.Compiler.compile(ast)

      assert result.rules == []
      assert [_condition] = result.conditions
    end
  end

  describe "loading under :strict — the point of A-60" do
    test "a signed conditions-only source loads" do
      {key, private} = keypair()

      start_supervised!(
        {Anemos.Runtime, name: :slsb_ok, keyring: %{"operator" => key}, unsigned_policy: :strict}
      )

      sig = sign(@conditions_only, private)

      assert :ok =
               Anemos.Runtime.load(:slsb_ok, @conditions_only,
                 authorization: %{signatures: %{"operator" => sig}}
               )
    end

    test "the same source with a bad signature is refused" do
      {key, _private} = keypair()
      {_other_key, attacker} = keypair()

      start_supervised!(
        {Anemos.Runtime, name: :slsb_bad, keyring: %{"operator" => key}, unsigned_policy: :strict}
      )

      sig = sign(@conditions_only, attacker)

      assert {:error, err} =
               Anemos.Runtime.load(:slsb_bad, @conditions_only,
                 authorization: %{signatures: %{"operator" => sig}}
               )

      assert err.code == "anemos.runtime/load_denied"
    end

    test "an unsigned conditions-only source is still refused under :strict" do
      start_supervised!({Anemos.Runtime, name: :slsb_unsigned, unsigned_policy: :strict})

      unsigned = """
      condition night {
        when EV { log "x" }
      }
      """

      assert {:error, err} = Anemos.Runtime.load(:slsb_unsigned, unsigned)
      assert err.code == "anemos.runtime/load_denied"
    end

    test "a conditions-only source that claims a signer is not laundered by :permit" do
      {key, _private} = keypair()

      start_supervised!(
        {Anemos.Runtime,
         name: :slsb_claim, keyring: %{"operator" => key}, unsigned_policy: :permit}
      )

      # Naming a signer is a provenance claim, so :permit must not treat the
      # source as merely unsigned — the same rule rule-level signers follow.
      assert {:error, err} = Anemos.Runtime.load(:slsb_claim, @conditions_only)
      assert err.code == "anemos.runtime/load_denied"
    end

    test "an unsigned conditions-only source still loads under :permit" do
      start_supervised!({Anemos.Runtime, name: :slsb_permit, unsigned_policy: :permit})

      unsigned = """
      condition night {
        when EV { log "x" }
      }
      """

      assert :ok = Anemos.Runtime.load(:slsb_permit, unsigned)
    end

    test "under :warn it loads and says so" do
      start_supervised!({Anemos.Runtime, name: :slsb_warn, unsigned_policy: :warn})

      unsigned = """
      condition night {
        when EV { log "x" }
      }
      """

      log = capture_log(fn -> assert :ok = Anemos.Runtime.load(:slsb_warn, unsigned) end)

      assert log =~ "unsigned policy"
    end
  end
end

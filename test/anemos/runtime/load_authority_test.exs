defmodule Anemos.Runtime.LoadAuthorityTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-12 — `load/2` has no trust boundary.

  Under the 2026-08-06 multi-tenant decision, whoever controls a `.rule`
  string controls every verb the host has registered. Loading is therefore
  a privileged operation and must be distinguishable from an ordinary
  runtime call: it goes through a configured authority, it has a size
  ceiling that no authority can waive, and it is *not* reachable from the
  generic `Comn.act/1` surface.
  """

  alias Anemos.Runtime.LoadAuthority

  @policy """
  rule r {
    when EV { log "ok" }
  }
  """

  defmodule DenyAll do
    @moduledoc false
    @behaviour Anemos.Runtime.LoadAuthority

    @impl true
    def authorize(_request), do: {:error, :not_today}
  end

  defmodule RequiresToken do
    @moduledoc false
    @behaviour Anemos.Runtime.LoadAuthority

    @impl true
    def authorize(%{authorization: "s3kr1t"}), do: :ok
    def authorize(_request), do: {:error, :bad_token}
  end

  defmodule Recording do
    @moduledoc false
    @behaviour Anemos.Runtime.LoadAuthority

    @impl true
    def authorize(request) do
      send(:load_authority_probe, {:authorize, request})
      :ok
    end
  end

  setup do
    on_exit(fn -> Application.delete_env(:anemos, :load_authority) end)
    :ok
  end

  describe "the Comn action surface" do
    test ":load is not reachable through Anemos.Runtime.act/1" do
      assert Anemos.Runtime.act(%{action: :load, name: :whatever, source: @policy}) ==
               {:error, :unknown_action}
    end

    test "choices/0 no longer advertises load as an action" do
      refute "load" in Anemos.Runtime.choices().actions
    end

    test "dispatch is still reachable — the gate is on loading, not on everything" do
      start_supervised!({Anemos.Runtime, name: :la_dispatch})
      assert {:ok, _} = Anemos.Runtime.act(%{action: :dispatch, name: :la_dispatch, event: "EV"})
    end
  end

  describe "the configured authority" do
    test "a denying authority stops the load and nothing is installed" do
      start_supervised!({Anemos.Runtime, name: :la_deny})
      Application.put_env(:anemos, :load_authority, DenyAll)

      assert {:error, err} = Anemos.Runtime.load(:la_deny, @policy)
      assert err.code == "anemos.runtime/load_denied"

      assert {:ok, []} = Anemos.Runtime.dispatch(:la_deny, "EV")
    end

    test "an authority that requires a token refuses a load without one" do
      start_supervised!({Anemos.Runtime, name: :la_token_bad})
      Application.put_env(:anemos, :load_authority, RequiresToken)

      assert {:error, err} = Anemos.Runtime.load(:la_token_bad, @policy)
      assert err.code == "anemos.runtime/load_denied"
    end

    test "the same authority admits a load carrying the token" do
      start_supervised!({Anemos.Runtime, name: :la_token_ok})
      Application.put_env(:anemos, :load_authority, RequiresToken)

      assert :ok = Anemos.Runtime.load(:la_token_ok, @policy, authorization: "s3kr1t")
    end

    test "the authority sees the source, its size, and the declared signer" do
      Process.register(self(), :load_authority_probe)

      start_supervised!({Anemos.Runtime, name: :la_probe})
      Application.put_env(:anemos, :load_authority, Recording)

      signed = """
      rule r {
        signed_by :operator
        when EV { log "ok" }
      }
      """

      assert :ok = Anemos.Runtime.load(:la_probe, signed, authorization: :tok)

      assert_received {:authorize, request}
      assert request.runtime == :la_probe
      assert request.source == signed
      assert request.byte_size == byte_size(signed)
      assert request.authorization == :tok
      assert request.signers == ["operator"]
    end

    test "the default authority preserves the existing embedder contract" do
      start_supervised!({Anemos.Runtime, name: :la_default})
      assert LoadAuthority.configured() == Anemos.Runtime.LoadAuthority.Permissive
      assert :ok = Anemos.Runtime.load(:la_default, @policy)
    end
  end

  describe "the size ceiling" do
    test "an oversized source is refused before it is parsed" do
      start_supervised!({Anemos.Runtime, name: :la_big})
      Application.put_env(:anemos, :max_policy_bytes, 64)
      on_exit(fn -> Application.delete_env(:anemos, :max_policy_bytes) end)

      assert {:error, err} = Anemos.Runtime.load(:la_big, @policy <> String.duplicate("\n", 200))
      assert err.code == "anemos.runtime/load_denied"
      assert err.message =~ "bytes"
    end

    test "no authority can waive the ceiling" do
      start_supervised!({Anemos.Runtime, name: :la_big_permissive})
      Application.put_env(:anemos, :max_policy_bytes, 8)
      on_exit(fn -> Application.delete_env(:anemos, :max_policy_bytes) end)

      assert {:error, err} = Anemos.Runtime.load(:la_big_permissive, @policy)
      assert err.code == "anemos.runtime/load_denied"
    end
  end

  describe "existing return contract" do
    test "a parse failure is still {:error, _} and is not wrapped as success" do
      start_supervised!({Anemos.Runtime, name: :la_parse})
      assert {:error, _} = Anemos.Runtime.load(:la_parse, "this is not a policy {{{")
    end

    test "a partial load is still {:partial, failures}" do
      start_supervised!({Anemos.Runtime, name: :la_partial})

      assert {:partial, [{:data_block, "missing", {:no_subscribable_handler, "nope"}}]} =
               Anemos.Runtime.load(:la_partial, """
               data missing {
                 dynamic {
                   subscribe nope "test://nowhere"
                 }
               }
               rule r {
                 when EV { log "ok" }
               }
               """)
    end
  end
end

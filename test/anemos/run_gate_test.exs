defmodule Anemos.RunGateTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-59 — `Anemos.run/2` and the CLI bypassed `LoadAuthority` entirely.

  There were two doors into the compiler and only one was gated.
  `Anemos.Runtime.load/3` checked the byte ceiling, parsed, and asked the
  configured authority before compiling; `Anemos.run/2` went straight from
  source to `Parser.parse` to `Compiler.compile`. The CLI calls
  `run_report/2`, so the one path that most obviously handles a policy file
  somebody else wrote was the one path with no gate.

  These tests hold the two doors to the same standard: whatever the
  configured authority refuses for `load/3`, it refuses for `run/2` and for
  `mix anemos.run` too.
  """

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
      send(:run_gate_probe, {:authorize, request})
      :ok
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:anemos, :load_authority)
      Application.delete_env(:anemos, :max_policy_bytes)
    end)

    :ok
  end

  describe "the authority gate applies to Anemos.run/2" do
    test "a denying authority refuses run/2 exactly as it refuses load/3" do
      Application.put_env(:anemos, :load_authority, DenyAll)

      assert {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/load_denied"}} =
               Anemos.run(@policy, event: "EV")
    end

    test "a denying authority refuses run_report/2" do
      Application.put_env(:anemos, :load_authority, DenyAll)

      assert {:error, %Comn.Errors.ErrorStruct{code: "anemos.runtime/load_denied"}} =
               Anemos.run_report(@policy, event: "EV")
    end

    test "the refusal names the authority and its reason, and not the source" do
      Application.put_env(:anemos, :load_authority, DenyAll)

      assert {:error, err} = Anemos.run(@policy, event: "EV")
      assert err.message =~ "DenyAll"
      assert err.message =~ "not_today"
      refute err.message =~ "log"
    end

    test "an authority that wants a token gets one through :authorization" do
      Application.put_env(:anemos, :load_authority, RequiresToken)

      assert {:error, _} = Anemos.run(@policy, event: "EV")
      assert {:ok, [_]} = Anemos.run(@policy, event: "EV", authorization: "s3kr1t")
    end

    test "the authority sees the parsed signers, so A-05 verification applies here too" do
      Process.register(self(), :run_gate_probe)
      Application.put_env(:anemos, :load_authority, Recording)

      signed = """
      rule r {
        signed_by :operator
        when EV { log "ok" }
      }
      """

      assert {:ok, [_]} = Anemos.run(signed, event: "EV")
      assert_receive {:authorize, request}
      assert request.signers == ["operator"]
      assert request.byte_size == byte_size(signed)
    end

    test "the permissive default leaves every existing caller alone" do
      assert {:ok, [%{type: :log}]} = Anemos.run(@policy, event: "EV")
    end
  end

  describe "the byte ceiling applies to Anemos.run/2" do
    test "source over the ceiling is refused before the parser sees it" do
      Application.put_env(:anemos, :max_policy_bytes, 32)

      assert {:error, err} = Anemos.run(@policy, event: "EV")
      assert err.code == "anemos.runtime/load_denied"
      assert err.message =~ "ceiling"
    end

    test "no authority can waive the ceiling" do
      Application.put_env(:anemos, :max_policy_bytes, 32)
      Application.put_env(:anemos, :load_authority, Anemos.Runtime.LoadAuthority.Permissive)

      assert {:error, err} = Anemos.run(@policy, event: "EV")
      assert err.message =~ "ceiling"
    end
  end

  describe "the CLI reports a refusal a policy author can act on" do
    setup do
      path = Path.join(System.tmp_dir!(), "a59_#{System.unique_integer([:positive])}.rule")
      File.write!(path, @policy)
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path}
    end

    test "a refused load exits non-zero and says who refused it", %{path: path} do
      Application.put_env(:anemos, :load_authority, DenyAll)

      assert {:error, lines} = Mix.Tasks.Anemos.Run.execute([path, "--event", "EV"])
      text = Enum.map_join(lines, "\n", fn {_level, t} -> t end)

      assert text =~ "load authority"
      assert text =~ "DenyAll"
      assert text =~ "not_today"
      refute text =~ "%Comn.Errors.ErrorStruct{"
    end

    test "the ceiling refusal reaches the CLI too", %{path: path} do
      Application.put_env(:anemos, :max_policy_bytes, 8)

      assert {:error, lines} = Mix.Tasks.Anemos.Run.execute([path, "--event", "EV"])
      text = Enum.map_join(lines, "\n", fn {_level, t} -> t end)
      assert text =~ "ceiling"
    end
  end
end

defmodule Anemos.Runtime.ErrorsTest do
  @moduledoc false
  use ExUnit.Case

  alias Comn.Errors.ErrorStruct

  setup do
    Code.ensure_loaded!(Anemos.Runtime.Errors)
    Comn.Errors.Registry.discover()
    :ok
  end

  describe "error code registration" do
    test "all anemos runtime codes are registered" do
      codes = Comn.Errors.Registry.codes_for_prefix("anemos.runtime/")
      assert "anemos.runtime/handler_crash" in codes
      assert "anemos.runtime/unknown_module" in codes
      assert "anemos.runtime/unknown_verb" in codes
      assert "anemos.runtime/unknown_capability" in codes
    end
  end

  describe "unknown_capability error" do
    test "includes the capability name in message" do
      demands = [%{capability: "ghost-cap", flag: :optional}]

      assert {:error, %ErrorStruct{} = err} = Anemos.Runtime.Demand.evaluate(demands, %{}, %{})
      assert err.code == "anemos.runtime/unknown_capability"
      assert err.reason == "validation"
      assert err.message =~ "ghost-cap"
    end
  end

  describe "handler_crash error" do
    test "includes rule name and reason in message" do
      start_supervised!({Anemos.Runtime, name: :test_err_crash})

      Anemos.Runtime.load(:test_err_crash, """
      rule bad-rule {
        when BOOM {
          log 1 + "not a number"
        }
      }
      """)

      {:ok, results} = Anemos.Runtime.dispatch(:test_err_crash, "BOOM")

      assert [{:error, %ErrorStruct{} = err}] = results
      assert err.code == "anemos.runtime/handler_crash"
      assert err.reason == "internal"
      assert err.message =~ "bad-rule"
    end

    test "error is enriched with request context" do
      start_supervised!({Anemos.Runtime, name: :test_err_ctx})

      Anemos.Runtime.load(:test_err_ctx, """
      rule crash {
        when EV {
          log 1 + "x"
        }
      }
      """)

      {:ok, results} =
        Anemos.Runtime.dispatch(:test_err_ctx, "EV", %{correlation_id: "corr-err-1"})

      assert [{:error, %ErrorStruct{} = err}] = results
      assert is_binary(err.request_id)
      assert err.correlation_id == "corr-err-1"
    end
  end

  describe "unknown_module error" do
    test "includes module name in message" do
      start_supervised!({Anemos.Runtime, name: :test_err_mod})

      Anemos.Runtime.load(:test_err_mod, """
      rule use-missing {
        when EV {
          [GHOST::invoke]
        }
      }
      """)

      {:ok, results} = Anemos.Runtime.dispatch(:test_err_mod, "EV")

      assert [{:error, %ErrorStruct{} = err}] = results
      assert err.code == "anemos.runtime/unknown_module"
      assert err.message =~ "GHOST"
    end
  end

  describe "unknown_verb error" do
    test "includes verb and module name in message" do
      err = Anemos.Runtime.Modules.Device.handle_verb("nonexistent", [], %{})
      assert {:error, %ErrorStruct{code: "anemos.runtime/unknown_verb"} = e} = err
      assert e.message =~ "nonexistent"
      assert e.message =~ "DEVICE"
    end
  end
end

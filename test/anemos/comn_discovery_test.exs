defmodule Anemos.ComnDiscoveryTest do
  @moduledoc false
  use ExUnit.Case

  describe "Anemos.Runtime Comn behaviour" do
    test "look returns a description" do
      assert is_binary(Anemos.Runtime.look())
      assert Anemos.Runtime.look() =~ "Runtime"
    end

    test "recon returns facade type" do
      assert %{type: :facade} = Anemos.Runtime.recon()
    end

    test "choices lists actions" do
      assert %{actions: actions} = Anemos.Runtime.choices()
      assert "dispatch" in actions
      assert "load" in actions
    end

    test "act with unknown action returns error" do
      assert {:error, :unknown_action} = Anemos.Runtime.act(%{action: :nope})
    end
  end

  describe "Anemos.Runtime.Dispatcher Comn behaviour" do
    test "look returns a description" do
      assert Anemos.Runtime.Dispatcher.look() =~ "Dispatcher"
    end

    test "recon returns implementation type with operations" do
      recon = Anemos.Runtime.Dispatcher.recon()
      assert recon.type == :implementation
      assert :command in recon.operations
      assert :emit in recon.operations
    end

    test "act with unknown action returns error" do
      assert {:error, :unknown_action} = Anemos.Runtime.Dispatcher.act(%{action: :nope})
    end
  end

  describe "Anemos.Runtime.ModuleRegistry Comn behaviour" do
    test "look returns a description" do
      assert Anemos.Runtime.ModuleRegistry.look() =~ "ModuleRegistry"
    end

    test "recon returns implementation type" do
      assert %{type: :implementation} = Anemos.Runtime.ModuleRegistry.recon()
    end

    test "act with unknown action returns error" do
      assert {:error, :unknown_action} = Anemos.Runtime.ModuleRegistry.act(%{action: :nope})
    end
  end

  describe "Anemos.Module macro injects Comn behaviour" do
    test "Device implements look/recon/choices" do
      assert Anemos.Runtime.Modules.Device.look() =~ "DEVICE"
      recon = Anemos.Runtime.Modules.Device.recon()
      assert recon.type == :implementation
      assert recon.anemos_name == "DEVICE"
      assert :set in recon.verbs
      assert :get in recon.verbs
    end

    test "File implements look/recon/choices" do
      assert Anemos.Runtime.Modules.File.look() =~ "FILE"
      choices = Anemos.Runtime.Modules.File.choices()
      assert "read" in choices.verbs
      assert "write" in choices.verbs
    end

    test "Device act delegates to handle_verb" do
      assert {:ok, %{module: "DEVICE", verb: "set", args: ["on"]}} =
               Anemos.Runtime.Modules.Device.act(%{verb: "set", args: ["on"], context: %{}})
    end

    test "Device act works without explicit context" do
      assert {:ok, %{module: "DEVICE", verb: "get", args: []}} =
               Anemos.Runtime.Modules.Device.act(%{verb: "get", args: []})
    end

    test "act with unknown action returns error" do
      assert {:error, :unknown_action} = Anemos.Runtime.Modules.Device.act(%{action: :nope})
    end
  end

  describe "Comn.Discovery integration" do
    setup do
      # Ensure Anemos modules are loaded in the BEAM before discovery scans
      Code.ensure_loaded!(Anemos.Runtime)
      Code.ensure_loaded!(Anemos.Runtime.Dispatcher)
      Code.ensure_loaded!(Anemos.Runtime.ModuleRegistry)
      Code.ensure_loaded!(Anemos.Runtime.Modules.Device)
      Code.ensure_loaded!(Anemos.Runtime.Modules.File)
      Comn.Discovery.discover()
      :ok
    end

    test "runtime modules are discoverable" do
      all = Comn.Discovery.all()
      assert Anemos.Runtime in all
      assert Anemos.Runtime.Dispatcher in all
      assert Anemos.Runtime.ModuleRegistry in all
      assert Anemos.Runtime.Modules.Device in all
      assert Anemos.Runtime.Modules.File in all
    end

    test "implementations_of filters correctly" do
      by_type = Comn.Discovery.by_type(:implementation)
      assert Anemos.Runtime.Dispatcher in by_type
      assert Anemos.Runtime.ModuleRegistry in by_type
      assert Anemos.Runtime.Modules.Device in by_type

      facades = Comn.Discovery.by_type(:facade)
      assert Anemos.Runtime in facades
    end
  end
end

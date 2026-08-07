defmodule Anemos.Runtime.ModuleRegistryTest do
  @moduledoc """
  A-10: verb routing must not be silently rebindable.

  The registry is reachable by a documented public name (`:"\#{name}.registry"`).
  If any process can rebind `"SECRET"` to a module of its choosing, every
  subsequent `[SECRET::unlock ...]` dispatches to it with arguments intact and
  the policy looks normal from outside.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Anemos.Runtime.ModuleRegistry
  alias Anemos.Runtime.Modules

  defmodule Attacker do
    @moduledoc false
    def handle_verb(_verb, args, _context), do: {:ok, {:exfiltrated, args}}
  end

  describe "first registration" do
    test "binds the name and logs it" do
      {:ok, reg} = ModuleRegistry.start_link([])

      log =
        capture_log(fn -> assert :ok = ModuleRegistry.register(reg, "SECRET", Modules.File) end)

      assert {:ok, Modules.File} = ModuleRegistry.lookup(reg, "SECRET")
      assert log =~ "SECRET"
      assert log =~ "Anemos.Runtime.Modules.File"
    end
  end

  describe "rebinding a live name" do
    setup do
      {:ok, reg} = ModuleRegistry.start_link([])
      :ok = ModuleRegistry.register(reg, "SECRET", Modules.File)
      %{reg: reg}
    end

    test "is rejected and the original binding survives", %{reg: reg} do
      capture_log(fn ->
        assert {:error, {:already_registered, Modules.File}} =
                 ModuleRegistry.register(reg, "SECRET", Attacker)
      end)

      assert {:ok, Modules.File} = ModuleRegistry.lookup(reg, "SECRET")
    end

    test "logs the attempt at :warning with both modules named", %{reg: reg} do
      log = capture_log(fn -> ModuleRegistry.register(reg, "SECRET", Attacker) end)

      assert log =~ "[warning]"
      assert log =~ "SECRET"
      assert log =~ inspect(Attacker)
      assert log =~ inspect(Modules.File)
    end

    test "re-registering the identical module is idempotent, not an error", %{reg: reg} do
      capture_log(fn ->
        assert :ok = ModuleRegistry.register(reg, "SECRET", Modules.File)
      end)

      assert {:ok, Modules.File} = ModuleRegistry.lookup(reg, "SECRET")
    end

    test "replace: true rebinds deliberately and logs at :warning", %{reg: reg} do
      log =
        capture_log(fn ->
          assert :ok = ModuleRegistry.register(reg, "SECRET", Attacker, replace: true)
        end)

      assert {:ok, Attacker} = ModuleRegistry.lookup(reg, "SECRET")
      assert log =~ "[warning]"
      assert log =~ "replaced"
    end
  end

  describe "registered?/2 and names/1" do
    test "expose the current bindings for auditing" do
      {:ok, reg} = ModuleRegistry.start_link([])
      capture_log(fn -> ModuleRegistry.register(reg, "DEVICE", Modules.Device) end)

      assert ModuleRegistry.registered?(reg, "DEVICE")
      refute ModuleRegistry.registered?(reg, "SECRET")
      assert ModuleRegistry.names(reg) == ["DEVICE"]
    end
  end

  describe "hijack scenario end to end" do
    test "a rule's verb still routes to the original module after a hijack attempt" do
      {:ok, reg} = ModuleRegistry.start_link([])
      capture_log(fn -> ModuleRegistry.register(reg, "DEVICE", Modules.Device) end)

      capture_log(fn ->
        assert {:error, {:already_registered, Modules.Device}} =
                 ModuleRegistry.register(reg, "DEVICE", Attacker)
      end)

      assert {:ok, mod} = ModuleRegistry.lookup(reg, "DEVICE")
      assert mod == Modules.Device
      refute match?({:ok, {:exfiltrated, _}}, mod.handle_verb("set", ["light", "on"], %{}))
    end
  end
end

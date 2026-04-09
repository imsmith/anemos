defmodule Anemos.ModuleTest do
  @moduledoc false
  use ExUnit.Case, async: true

  defmodule TestSecret do
    @moduledoc false
    use Anemos.Module, name: "SECRET"

    verb :unlock, fn args, _ctx -> {:ok, {:unlocked, args}} end
    verb :rotate, fn _args, ctx -> {:ok, {:rotated, ctx[:key]}} end
  end

  test "module carries its name" do
    assert TestSecret.__anemos_name__() == "SECRET"
  end

  test "module lists its verbs" do
    assert :unlock in TestSecret.__anemos_verbs__()
    assert :rotate in TestSecret.__anemos_verbs__()
  end

  test "handle_verb dispatches to registered function" do
    assert {:ok, {:unlocked, ["key123"]}} = TestSecret.handle_verb("unlock", ["key123"], %{})
  end

  test "handle_verb passes context to function" do
    assert {:ok, {:rotated, "abc"}} = TestSecret.handle_verb("rotate", [], %{key: "abc"})
  end

  test "unknown verb returns error" do
    assert {:error, {:unknown_verb, "SECRET", "nonexistent"}} =
             TestSecret.handle_verb("nonexistent", [], %{})
  end

  test "implements Anemos.Runtime.Module behaviour" do
    behaviours =
      TestSecret.__info__(:attributes)
      |> Keyword.get_values(:behaviour)
      |> List.flatten()

    assert Anemos.Runtime.Module in behaviours
  end

  test "works with Runtime.register/2" do
    start_supervised!({Anemos.Runtime, name: :test_macro_mod})

    Anemos.Runtime.register(:test_macro_mod, TestSecret)

    Anemos.Runtime.load(:test_macro_mod, """
    rule use-secret {
      when UNLOCK {
        [SECRET::unlock "my-key"]
      }
    }
    """)

    {:ok, results} = Anemos.Runtime.dispatch(:test_macro_mod, "UNLOCK")
    assert [{:unlocked, ["my-key"]}] = results
  end
end

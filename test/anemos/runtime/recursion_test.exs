defmodule Anemos.Runtime.RecursionTest do
  @moduledoc """
  Regression tests for unbounded event recursion.

  `emit <label>`, `nextevent` and `nextrule` all re-enter the dispatch loop.
  Without a depth ceiling a cyclic policy spins the dispatcher at 100% CPU
  until the VM dies; the caller only sees a 5s GenServer timeout.
  """
  use ExUnit.Case, async: false

  @moduletag timeout: 60_000

  defp recursion_error?({:error, %{code: code}}),
    do: code == "anemos.runtime/event_recursion_limit"

  defp recursion_error?(_), do: false

  test "mutual nextevent terminates with a structured error" do
    start_supervised!({Anemos.Runtime, name: :rec_nextevent})

    :ok =
      Anemos.Runtime.load(:rec_nextevent, """
      rule a {
        when A {
          nextevent B
        }
      }

      rule b {
        when B {
          nextevent A
        }
      }
      """)

    {:ok, results} = Anemos.Runtime.dispatch(:rec_nextevent, "A")

    assert Enum.any?(results, &recursion_error?/1),
           "expected an event_recursion_limit error, got: #{inspect(Enum.take(results, 5))}"
  end

  test "mutual emit-with-label terminates with a structured error" do
    start_supervised!({Anemos.Runtime, name: :rec_emit})
    :ok = Anemos.Runtime.register(:rec_emit, "DEVICE", Anemos.Runtime.Modules.Device)

    :ok =
      Anemos.Runtime.load(:rec_emit, """
      rule a {
        when A {
          emit [DEVICE::set "x" "to-b"] as :B
        }
      }

      rule b {
        when B {
          emit [DEVICE::set "x" "to-a"] as :A
        }
      }
      """)

    {:ok, results} = Anemos.Runtime.dispatch(:rec_emit, "A")

    assert Enum.any?(results, &recursion_error?/1),
           "expected an event_recursion_limit error, got: #{inspect(Enum.take(results, 5))}"
  end

  test "self-referential nextrule terminates with a structured error" do
    start_supervised!({Anemos.Runtime, name: :rec_nextrule})

    :ok =
      Anemos.Runtime.load(:rec_nextrule, """
      rule a {
        when A {
          nextrule a
        }
      }
      """)

    {:ok, results} = Anemos.Runtime.dispatch(:rec_nextrule, "A")

    assert Enum.any?(results, &recursion_error?/1),
           "expected an event_recursion_limit error, got: #{inspect(Enum.take(results, 5))}"
  end

  test "the runtime stays usable after hitting the recursion ceiling" do
    start_supervised!({Anemos.Runtime, name: :rec_survives})

    :ok =
      Anemos.Runtime.load(:rec_survives, """
      rule a {
        when A {
          nextevent B
        }
      }

      rule b {
        when B {
          nextevent A
        }
      }

      rule sane {
        when SANE {
          log "sane"
        }
      }
      """)

    dispatcher = Process.whereis(:"rec_survives.dispatcher")
    {:ok, _} = Anemos.Runtime.dispatch(:rec_survives, "A")

    assert Process.whereis(:"rec_survives.dispatcher") == dispatcher,
           "dispatcher crashed instead of returning a structured error"

    assert {:ok, [%{type: :log, value: "sane"}]} = Anemos.Runtime.dispatch(:rec_survives, "SANE")
  end

  test "a non-cyclic emit chain is unaffected" do
    start_supervised!({Anemos.Runtime, name: :rec_ok})

    :ok =
      Anemos.Runtime.load(:rec_ok, """
      rule a {
        when A {
          nextevent B
        }
      }

      rule b {
        when B {
          log "b ran"
        }
      }
      """)

    {:ok, results} = Anemos.Runtime.dispatch(:rec_ok, "A")
    assert Enum.any?(results, &match?(%{type: :log, value: "b ran"}, &1))
    refute Enum.any?(results, &recursion_error?/1)
  end
end

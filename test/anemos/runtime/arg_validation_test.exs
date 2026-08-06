defmodule Anemos.Runtime.ArgValidationTest do
  use ExUnit.Case, async: false

  @moduledoc """
  A-11 — no input validation between the DSL and host verbs.

  Policy text is untrusted. Every assertion here is about a *closed* door:
  an arg that violates the verb's declared schema must never reach
  `handle_verb/3`, and a path that escapes its configured root must never
  reach the host filesystem call.
  """

  alias Anemos.Compiler
  alias Anemos.Parser
  alias Anemos.Runtime.{Dispatcher, ModuleRegistry, PathGuard}

  # Echoes back exactly what reached it, so a test can distinguish
  # "rejected before the host" from "accepted and quietly ignored".
  defmodule Recorder do
    @moduledoc false
    @behaviour Anemos.Runtime.Module

    @impl true
    def arg_schema("set"), do: [[type: :string, max_bytes: 8], [type: :string]]
    def arg_schema("read"), do: [[type: :string, path: :test_root]]
    def arg_schema("mode"), do: [[type: :string, in: ["on", "off"]]]
    def arg_schema(_verb), do: nil

    @impl true
    def handle_verb(verb, args, context) do
      {:ok, %{verb: verb, args: args, context: context}}
    end
  end

  defp dispatcher_for(source) do
    {:ok, ast} = Parser.parse(source)
    {:ok, compiled} = Compiler.compile(ast)
    {:ok, registry} = ModuleRegistry.start_link([])
    ModuleRegistry.register(registry, "REC", Recorder)

    {:ok, dispatcher} =
      Anemos.Runtime.Standalone.start_link(rules: compiled.rules, registry: registry)

    dispatcher
  end

  describe "arg schema enforcement" do
    test "an over-long string argument is rejected before the host verb runs" do
      dispatcher =
        dispatcher_for("""
        rule overlong {
          when EV {
            [REC::set "aaaaaaaaaaaaaaaaaaaaaaaa" "x"]
          }
        }
        """)

      assert [{:error, err}] = Dispatcher.dispatch(dispatcher, "EV")
      assert err.code == "anemos.runtime/invalid_argument"
    end

    test "a wrong-arity call is rejected before the host verb runs" do
      dispatcher =
        dispatcher_for("""
        rule arity {
          when EV {
            [REC::set "ok"]
          }
        }
        """)

      assert [{:error, err}] = Dispatcher.dispatch(dispatcher, "EV")
      assert err.code == "anemos.runtime/invalid_argument"
    end

    test "a value outside the allow-list is rejected" do
      dispatcher =
        dispatcher_for("""
        rule allowlist {
          when EV {
            [REC::mode "sudo"]
          }
        }
        """)

      assert [{:error, err}] = Dispatcher.dispatch(dispatcher, "EV")
      assert err.code == "anemos.runtime/invalid_argument"
    end

    test "a conforming call still reaches the host verb" do
      dispatcher =
        dispatcher_for("""
        rule ok {
          when EV {
            [REC::mode "on"]
          }
        }
        """)

      assert [{:ok, %{verb: "mode", args: ["on"]}}] = Dispatcher.dispatch(dispatcher, "EV")
    end

    test "a verb with no schema is unvalidated — existing modules keep working" do
      dispatcher =
        dispatcher_for("""
        rule unschema {
          when EV {
            [REC::anything "whatever" "shape"]
          }
        }
        """)

      assert [{:ok, %{verb: "anything", args: ["whatever", "shape"]}}] =
               Dispatcher.dispatch(dispatcher, "EV")
    end

    test "the rejection message does not disclose the offending value" do
      dispatcher =
        dispatcher_for("""
        rule leak {
          when EV {
            [REC::set "hunter2-hunter2-hunter2" "x"]
          }
        }
        """)

      assert [{:error, err}] = Dispatcher.dispatch(dispatcher, "EV")
      refute err.message =~ "hunter2"
    end
  end

  describe "path confinement" do
    @tag :tmp_dir
    test "a traversal argument is rejected before the host verb runs", %{tmp_dir: tmp} do
      Application.put_env(:anemos, :path_roots, %{test_root: tmp})
      on_exit(fn -> Application.delete_env(:anemos, :path_roots) end)

      dispatcher =
        dispatcher_for("""
        rule traversal {
          when EV {
            [REC::read "../../etc/shadow"]
          }
        }
        """)

      assert [{:error, err}] = Dispatcher.dispatch(dispatcher, "EV")
      assert err.code == "anemos.runtime/invalid_argument"
    end

    @tag :tmp_dir
    test "a confined path reaches the host verb already expanded", %{tmp_dir: tmp} do
      Application.put_env(:anemos, :path_roots, %{test_root: tmp})
      on_exit(fn -> Application.delete_env(:anemos, :path_roots) end)

      dispatcher =
        dispatcher_for("""
        rule confined {
          when EV {
            [REC::read "notes/a.txt"]
          }
        }
        """)

      assert [{:ok, %{args: [expanded]}}] = Dispatcher.dispatch(dispatcher, "EV")
      assert expanded == Path.join(tmp, "notes/a.txt")
    end

    @tag :tmp_dir
    test "an unconfigured root denies rather than passing the path through", %{tmp_dir: _tmp} do
      Application.delete_env(:anemos, :path_roots)

      dispatcher =
        dispatcher_for("""
        rule noroot {
          when EV {
            [REC::read "a.txt"]
          }
        }
        """)

      assert [{:error, err}] = Dispatcher.dispatch(dispatcher, "EV")
      assert err.code == "anemos.runtime/invalid_argument"
    end

    @tag :tmp_dir
    test "PathGuard.confine/2 is directly usable by a host module author", %{tmp_dir: tmp} do
      assert {:ok, path} = PathGuard.confine("a/b.txt", tmp)
      assert path == Path.join(tmp, "a/b.txt")

      assert {:error, :outside_root} = PathGuard.confine("../escape", tmp)
      assert {:error, :outside_root} = PathGuard.confine("/etc/shadow", tmp)
      assert {:error, :not_a_path} = PathGuard.confine(<<0>> <> "x", tmp)
    end

    @tag :tmp_dir
    test "a sibling directory sharing a string prefix does not count as confined", %{tmp_dir: tmp} do
      root = Path.join(tmp, "root")
      File.mkdir_p!(root)
      assert {:error, :outside_root} = PathGuard.confine(Path.join(tmp, "rootless/x"), root)
    end
  end

  describe "verb context" do
    test "the context handed to a host verb carries no live store pids" do
      dispatcher =
        dispatcher_for("""
        rule ctx {
          when EV {
            [REC::anything "x"]
          }
        }
        """)

      assert [{:ok, %{context: context}}] = Dispatcher.dispatch(dispatcher, "EV")
      refute Map.has_key?(context, :data_store)

      for {_k, v} <- context do
        refute is_pid(v), "verb context leaked a process handle: #{inspect(context)}"
      end
    end
  end
end

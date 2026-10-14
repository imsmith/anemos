defmodule Anemos.DataQueryTest do
  @moduledoc """
  A-34, A-35. A format `data` block is built by the handler registered for
  its format; a `query` is run by the handler registered for its engine and
  is called by naming it, `?name`. What policy text names and the runtime
  does not hold is an error where it is reached, not a quiet `false`.
  """
  use ExUnit.Case, async: false

  alias Anemos.Runtime
  alias Comn.Errors.ErrorStruct

  defmodule Words do
    @moduledoc false
    @behaviour Anemos.DataModel
    def keyword, do: "words"
    def parse(raw), do: {:ok, String.split(raw)}
    def eval(parsed, _context), do: {:ok, parsed}

    def transduce(data, _shape, "resource.transducer.upcase"),
      do: {:ok, Enum.map(data, &String.upcase/1)}

    def transduce(_data, _shape, _transducer), do: {:error, :not_supported}
  end

  defmodule Greeter do
    @moduledoc false
    @behaviour Anemos.DataModel
    def keyword, do: "greeter"
    def parse(raw), do: {:ok, String.trim(raw)}

    def eval(greeting, %{bindings: bindings}),
      do: {:ok, %{"line" => "#{greeting} #{bindings["name"]}", "inputs" => bindings}}

    def transduce(_data, _shape, _transducer), do: {:error, :not_supported}
  end

  defmodule Boom do
    @moduledoc false
    @behaviour Anemos.DataModel
    def keyword, do: "boom"
    def parse(_raw), do: raise("no")
    def eval(parsed, _context), do: {:ok, parsed}
    def transduce(_data, _shape, _transducer), do: {:error, :not_supported}
  end

  defmodule Refuses do
    @moduledoc false
    def subscribe(_protocol, _uri, _callback), do: {:error, :refused}
    def unsubscribe(_ref), do: :ok
  end

  setup context do
    rt = :"dq_#{:erlang.phash2(context.test)}"
    start_supervised!({Runtime, name: rt})
    for handler <- [Words, Greeter, Boom], do: :ok = Runtime.register_data_model(rt, handler)
    {:ok, rt: rt}
  end

  defp logs(rt, event, context \\ %{}) do
    {:ok, results} = Runtime.dispatch(rt, event, context)
    for %{type: :log, value: v} <- results, do: v
  end

  defp error_code(rt, event, context \\ %{}) do
    {:ok, results} = Runtime.dispatch(rt, event, context)
    assert [%ErrorStruct{code: code}] = for({:error, e} <- results, do: e)
    code
  end

  @member """
  rule check {
    when EV {
      if ?who memberof(crew) { log "in" } else { log "out" }
    }
  }
  """

  describe "format data blocks (A-34)" do
    test "the handler's parse is the dataset", %{rt: rt} do
      assert :ok = Runtime.load(rt, "data crew { words { alice bob } }\n" <> @member)
      assert logs(rt, "EV", %{context_data: %{"who" => "alice"}}) == ["in"]
      assert logs(rt, "EV", %{context_data: %{"who" => "mallory"}}) == ["out"]
    end

    test "a format with no handler fails the load and the block is not registered", %{rt: rt} do
      assert {:partial, [%{code: "anemos.data/no_data_model", field: "crew"}]} =
               Runtime.load(rt, "data crew { nosuch { alice } }\n" <> @member)

      assert error_code(rt, "EV", %{context_data: %{"who" => "alice"}}) ==
               "anemos.runtime/unknown_dataset"
    end

    test "a handler that raises fails the load and leaves the runtime standing", %{rt: rt} do
      assert {:partial, [%{code: "anemos.data/data_model_failed", field: "crew"}]} =
               Runtime.load(rt, "data crew { boom { x } }\n" <> @member)

      assert error_code(rt, "EV", %{context_data: %{"who" => "x"}}) ==
               "anemos.runtime/unknown_dataset"
    end

    test "a block inside a rule is scoped to that rule", %{rt: rt} do
      assert :ok =
               Runtime.load(rt, """
               rule inner {
                 data crew { words { alice } }
                 when EV {
                   if ?who memberof(crew) { log "in" } else { log "out" }
                 }
               }
               rule outer {
                 when EV {
                   if ?who memberof(crew) { log "leaked" }
                 }
               }
               """)

      {:ok, results} = Runtime.dispatch(rt, "EV", %{context_data: %{"who" => "alice"}})
      assert %{type: :log, value: "in"} in results

      assert [%ErrorStruct{code: "anemos.runtime/unknown_dataset"}] =
               for({:error, e} <- results, do: e)

      refute %{type: :log, value: "leaked"} in results
    end

    test "`transclude ... as name` registers the transduced value under that name", %{rt: rt} do
      assert :ok =
               Runtime.load(rt, """
               data crew {
                 words { alice bob }
                 transclude to shape(resource.schema.crew) with resource.transducer.upcase as loud
               }
               rule r {
                 when EV {
                   if "ALICE" memberof(loud) { log "loud" }
                   if "alice" memberof(crew) { log "quiet" }
                 }
               }
               """)

      assert logs(rt, "EV") == ["loud", "quiet"]
    end

    test "a transducer the handler does not support fails the load", %{rt: rt} do
      assert {:partial, [%{code: "anemos.data/data_model_failed", field: "crew"}]} =
               Runtime.load(rt, """
               data crew {
                 words { alice }
                 transclude to shape(a.b) with resource.transducer.nosuch as loud
               }
               """)
    end

    test "`?name` reads a data block by name", %{rt: rt} do
      assert :ok =
               Runtime.load(rt, """
               data crew { words { alice } }
               rule r { when EV { log ?crew } }
               """)

      assert logs(rt, "EV") == [MapSet.new(["alice"])]
    end
  end

  @greet """
  query greet {
    expect :name
    greeter { hello }
    return ?line
  }
  """

  describe "queries (A-35)" do
    test "a query is called by naming it, with what it expects taken from scope", %{rt: rt} do
      assert :ok =
               Runtime.load(
                 rt,
                 @greet <> ~s|rule r { when EV {\n let name = "ian"\n log ?greet\n } }|
               )

      assert logs(rt, "EV") == ["hello ian"]
    end

    test "an expected binding may come from a `set` or from context data", %{rt: rt} do
      assert :ok = Runtime.load(rt, @greet <> ~s|rule r { when EV { log ?greet } }|)
      assert logs(rt, "EV", %{context_data: %{"name" => "ctx"}}) == ["hello ctx"]
    end

    test "context data of the same name is read before the query", %{rt: rt} do
      assert :ok = Runtime.load(rt, @greet <> ~s|rule r { when EV { log ?greet } }|)
      assert logs(rt, "EV", %{context_data: %{"greet" => "data wins"}}) == ["data wins"]
    end

    test "an expected binding that is not bound is an error, and the body stops", %{rt: rt} do
      assert :ok =
               Runtime.load(rt, @greet <> ~s|rule r { when EV {\n log ?greet\n log "after"\n } }|)

      assert error_code(rt, "EV") == "anemos.runtime/query_missing_binding"
      assert logs(rt, "EV") == []
    end

    test "an engine with no handler is an error when the query is called", %{rt: rt} do
      assert :ok =
               Runtime.load(rt, """
               query q {
                 nosuch { x }
                 return ?y
               }
               rule r { when EV { log ?q } }
               """)

      assert error_code(rt, "EV") == "anemos.runtime/unknown_data_model"
    end

    test "an engine that raises is a failed query, not a crashed rule", %{rt: rt} do
      assert :ok =
               Runtime.load(rt, """
               query q {
                 boom { x }
                 return ?y
               }
               rule r { when EV { log ?q } }
               """)

      assert error_code(rt, "EV") == "anemos.runtime/query_failed"
    end

    test "a `return` the engine did not bind is a failed query", %{rt: rt} do
      assert :ok =
               Runtime.load(rt, """
               query q {
                 expect :name
                 greeter { hello }
                 return ?nosuch
               }
               rule r { when EV { log ?q } }
               """)

      assert error_code(rt, "EV", %{context_data: %{"name" => "x"}}) ==
               "anemos.runtime/query_failed"
    end

    test "a query inside a rule shadows a global one, for that rule only", %{rt: rt} do
      assert :ok =
               Runtime.load(
                 rt,
                 @greet <>
                   """
                   rule inner {
                     query greet {
                       expect :name
                       greeter { howdy }
                       return ?line
                     }
                     when EV { log ?greet }
                   }
                   rule outer { when EV { log ?greet } }
                   """
               )

      assert Enum.sort(logs(rt, "EV", %{context_data: %{"name" => "x"}})) ==
               ["hello x", "howdy x"]
    end

    test "a query goes with the policy that declared it", %{rt: rt} do
      assert :ok = Runtime.load(rt, @greet, policy: "queries")
      assert :ok = Runtime.load(rt, ~s|rule r { when EV { log ?greet } }|, policy: "rules")
      assert logs(rt, "EV", %{context_data: %{"name" => "x"}}) == ["hello x"]

      :ok = Runtime.unload(rt, "queries")
      assert logs(rt, "EV", %{context_data: %{"name" => "x"}}) == [nil]
    end
  end

  describe "what is named and not held is an error where it is reached" do
    test "`nextrule` to a rule that is not loaded", %{rt: rt} do
      assert :ok = Runtime.load(rt, ~s|rule r { when EV { nextrule nosuch } }|)
      assert error_code(rt, "EV") == "anemos.runtime/unknown_rule"
    end

    test "`memberof` a data block that is not registered", %{rt: rt} do
      assert :ok = Runtime.load(rt, @member)

      assert error_code(rt, "EV", %{context_data: %{"who" => "x"}}) ==
               "anemos.runtime/unknown_dataset"
    end

    test "A-26: a data block whose feed refused to start", %{rt: rt} do
      :ok = Runtime.Dispatcher.register_subscribable(:"#{rt}.dispatcher", "feed", Refuses)

      assert {:partial, [%{code: "anemos.data/subscribe_failed", field: "crew"}]} =
               Runtime.load(
                 rt,
                 ~s|data crew { dynamic { subscribe feed "test://x" } }\n| <> @member
               )

      assert error_code(rt, "EV", %{context_data: %{"who" => "x"}}) ==
               "anemos.runtime/unknown_dataset"
    end

    test "a `nextrule` target loaded later is found", %{rt: rt} do
      assert :ok = Runtime.load(rt, ~s|rule r { when EV { nextrule later } }|)
      assert :ok = Runtime.load(rt, ~s|rule later { when OTHER { log "found" } }|)
      assert logs(rt, "EV") == ["found"]
    end
  end
end

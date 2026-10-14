defmodule Anemos.StructuredErrorsTest do
  @moduledoc """
  A-22. Every error Anemos answers is `{:error, %Comn.Errors.ErrorStruct{}}`
  — or, for a load that left declarations inert, a list of them. The `code`
  is what a caller matches; nothing answers a bare string or an ad-hoc tuple.
  """
  use ExUnit.Case, async: false

  alias Anemos.Runtime
  alias Comn.Errors.ErrorStruct

  defmodule Host do
    @moduledoc false
    @behaviour Anemos.Runtime.Module
    @impl true
    def handle_verb("refuse", _args, _ctx), do: {:error, {:denied, "s3cret-value"}}

    def handle_verb("structured", _args, _ctx),
      do: {:error, Comn.Errors.Registry.error!("anemos.runtime/unknown_verb", field: "own")}
  end

  setup context do
    rt = :"se_#{:erlang.phash2(context.test)}"
    start_supervised!({Runtime, name: rt})
    :ok = Runtime.register(rt, "HOST", Host)
    {:ok, rt: rt}
  end

  defp code({:error, %ErrorStruct{code: code}}), do: code

  test "lexing, parsing and compiling" do
    assert code(Anemos.Lexer.tokenize("@@@")) == "anemos.lexer/invalid_token"
    assert code(Anemos.Parser.parse("@@@")) == "anemos.lexer/invalid_token"
    assert code(Anemos.Parser.parse("rule {")) == "anemos.parser/syntax_error"

    {:ok, ast} = Anemos.Parser.parse(~s|rule r { when EV { log @x } }|)
    assert code(Anemos.Compiler.compile(ast)) == "anemos.compiler/invalid_policy"
    assert code(Anemos.run("rule {", event: "EV")) == "anemos.parser/syntax_error"
  end

  test "loading and unloading", %{rt: rt} do
    assert code(Runtime.load(rt, "rule {")) == "anemos.parser/syntax_error"

    assert code(Runtime.load(rt, "rule r { when EV { log 1 } }", policy: "")) ==
             "anemos.runtime/invalid_option"

    assert code(Runtime.unload(rt, "nosuch")) == "anemos.runtime/not_loaded"

    :ok = Runtime.load(rt, "rule r { when EV { log 1 } }", policy: "a")

    assert code(Runtime.load(rt, "rule r { when EV { log 2 } }", policy: "b")) ==
             "anemos.runtime/name_taken"
  end

  test "a load that leaves declarations inert lists a structured error for each", %{rt: rt} do
    assert {:partial, failures} =
             Runtime.load(rt, """
             data feed { dynamic { subscribe nosuch "test://x" } }
             rule stale { at DATE_1999.01.01 { log "never" } }
             """)

    assert Enum.all?(failures, &match?(%ErrorStruct{}, &1))

    assert Enum.sort(Enum.map(failures, & &1.code)) ==
             ["anemos.data/no_subscribable_handler", "anemos.scheduler/date_in_past"]
  end

  test "everything a dispatch can answer as an error", %{rt: rt} do
    :ok =
      Runtime.load(rt, """
      capability broken { on demand { log 1 / 0 } }
      rule a { when A { [HOST::refuse] } }
      rule b { when B { [HOST::structured] } }
      rule c { when C { [NOSUCH::go] } }
      rule d { when D { demand nosuch } }
      rule e { when E { nextrule nosuch } }
      rule f { when F { log 1 / 0 } }
      """)

    for {event, expected} <- [
          {"A", "anemos.runtime/verb_failed"},
          {"B", "anemos.runtime/unknown_verb"},
          {"C", "anemos.runtime/unknown_module"},
          {"D", "anemos.runtime/unknown_capability"},
          {"E", "anemos.runtime/unknown_rule"},
          {"F", "anemos.runtime/handler_crash"}
        ] do
      assert {:ok, results} = Runtime.dispatch(rt, event)
      assert [%ErrorStruct{code: ^expected}] = for({:error, e} <- results, do: e)
    end
  end

  test "a host verb's own failure term is carried as a tag, not as values", %{rt: rt} do
    :ok = Runtime.load(rt, "rule a { when A { [HOST::refuse] } }")
    assert {:ok, [{:error, %ErrorStruct{} = error}]} = Runtime.dispatch(rt, "A")
    assert error.field == "HOST::refuse"
    assert error.message =~ ":denied"
    refute inspect(error) =~ "s3cret-value"
  end

  test "the standalone pieces" do
    alias Anemos.Runtime.{ArgSchema, Duration, ModuleRegistry, NLD, PathGuard, TrustStore}

    assert code(ArgSchema.validate([[type: :integer]], ["x"], "v")) ==
             "anemos.runtime/invalid_argument"

    assert code(PathGuard.confine("../x", "/srv")) == "anemos.path/outside_root"
    assert code(PathGuard.confine(1, "/srv")) == "anemos.path/not_a_path"
    assert code(PathGuard.confine_root("x", :nowhere)) == "anemos.path/unknown_root"
    assert code(Duration.to_ms({1, :fortnights})) == "anemos.duration/unknown_unit"
    assert code(Duration.to_ms("soon")) == "anemos.duration/invalid"
    assert code(NLD.resolve("gibberish")) == "anemos.nld/unknown_expression"
    assert code(TrustStore.fetch(:no_such_runtime)) == "anemos.trust/no_trust_store"
    assert code(Runtime.act(%{action: :nope})) == "anemos.runtime/unknown_action"

    {:ok, reg} = ModuleRegistry.start_link([])
    :ok = ModuleRegistry.register(reg, "HOST", Host)

    assert code(ModuleRegistry.register(reg, "HOST", __MODULE__)) ==
             "anemos.runtime/already_registered"
  end
end

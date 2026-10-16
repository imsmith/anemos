defmodule Anemos.ManualTest do
  @moduledoc """
  Keeps the user manual's complete policy listings and behavioral examples
  tied to the interpreter. Syntax templates use `text` fences deliberately.
  """
  use ExUnit.Case, async: true

  alias Anemos.{Compiler, Parser, Runtime}

  defmodule Probe do
    @moduledoc false
    use Anemos.Module, name: "PROBE"

    verb :record, fn [tag], %{context_data: %{"recipient" => recipient}} ->
      send(recipient, {:called, tag})
      {:ok, tag}
    end
  end

  @manual Path.expand("../../docs/manual", __DIR__)
  @chapters Path.wildcard(Path.join(@manual, "*.md"))

  for path <- @chapters,
      {[_, source], index} <-
        Enum.with_index(Regex.scan(~r/^```anemos\n(.*?)^```/ms, File.read!(path)), 1) do
    @source source
    test "#{Path.basename(path)} listing #{index} parses and compiles" do
      assert {:ok, ast} = Parser.parse(@source)
      assert {:ok, _compiled} = Compiler.compile(ast)
    end
  end

  test "manual links resolve to files and section headings" do
    for path <- @chapters,
        [_, destination] <- Regex.scan(~r/\[[^\]]+\]\(([^)]+)\)/, File.read!(path)),
        not String.contains?(destination, "://") do
      [file | fragment] = String.split(destination, "#", parts: 2)
      target = if file == "", do: path, else: Path.expand(file, Path.dirname(path))
      assert File.regular?(target), "#{path}: missing linked file #{destination}"

      if fragment != [] do
        headings =
          for [_, heading] <- Regex.scan(~r/^\#+ (.+)$/m, File.read!(target)) do
            heading
            |> String.downcase()
            |> String.replace(~r/[^\p{L}\p{N}\s_-]/u, "")
            |> String.replace(~r/\s/u, "-")
          end

        assert hd(fragment) in headings, "#{path}: missing linked section #{destination}"
      end
    end
  end

  for path <- Path.wildcard(Path.join(@manual, "examples/*.rule")) do
    @path path
    test "example file #{Path.basename(path)} parses and compiles" do
      assert {:ok, ast} = @path |> File.read!() |> Parser.parse()
      assert {:ok, _compiled} = Compiler.compile(ast)
    end
  end

  test "first chapter CLI examples have their promised outcomes" do
    assert {:ok, hello} = cli("hello", ["--event", "MOTION"])
    assert Enum.any?(hello, fn {_, line} -> line =~ ~s(log "Motion detected") end)

    assert {:ok, greeting} = cli("greet", ["--event", "ARRIVAL", "--context-data", "visitor=Ada"])
    assert Enum.any?(greeting, fn {_, line} -> line =~ ~s(log "Welcome back") end)

    assert {:ok, denied} = cli("garage", ["--event", "MOTION"])
    assert Enum.any?(denied, fn {_, line} -> line =~ "none is reachable" end)

    assert {:ok, admitted} = cli("garage", ["--event", "MOTION", "--context", "garage.sensor"])
    assert Enum.any?(admitted, fn {_, line} -> line =~ ~s(log "Garage motion detected") end)
  end

  test "the downloadable walkthroughs check state, pipelines, datasets and handlers" do
    Code.eval_file(Path.join(@manual, "examples/walkthrough.exs"))
    Code.eval_file(Path.join(@manual, "examples/data_models.exs"))
    Code.eval_file(Path.join(@manual, "examples/workshop.exs"))
  end

  test "chapter 6 distinguishes repeated compound reports from condition transitions" do
    rt = :manual_reports
    start_supervised!({Runtime, name: rt})

    :ok =
      Runtime.load(rt, """
      rule repeated {
        when (A AND B) { log "rule" }
      }
      condition ready {
        when (A AND B) { log "condition" }
      }
      """)

    reports = [{"A", true}, {"B", true}, {"A", true}, {"B", false}, {"B", true}]

    values =
      Enum.flat_map(reports, fn {event, state} ->
        logs(rt, event, %{"state" => state})
      end)

    assert Enum.count(values, &(&1 == "rule")) == 3
    assert Enum.count(values, &(&1 == "condition")) == 2
  end

  test "the documented handoff broadcasts and overlays the original payload" do
    rt = :manual_handoff
    start_supervised!({Runtime, name: rt})

    :ok =
      Runtime.load(rt, """
      rule begin-job {
        when START {
          let destination = ?path
          nextevent PROCESS with { path: @destination, stage: "processing" }
          log "unreachable"
        }
      }
      rule process-job {
        when PROCESS {
          log ?path
          log ?stage
          log ?request_id
        }
      }
      """)

    assert logs(rt, "START", %{"path" => "a.pdf", "request_id" => "req-1"}) ==
             ["a.pdf", "processing", "req-1"]
  end

  test "the documented demand limit does not promise an execution gate" do
    rt = :manual_demand
    start_supervised!({Runtime, name: rt})
    :ok = Runtime.load(rt, ~s|rule r { when GO { demand absent\n log "after" } }|)
    {:ok, results} = Runtime.dispatch(rt, "GO")
    assert {:error, %{code: "anemos.runtime/unknown_capability"}} = hd(results)
    assert %{type: :log, value: "after"} in results
  end

  test "the explicit run-once recipe retains its completion state" do
    rt = :manual_once
    start_supervised!({Runtime, name: rt})

    :ok =
      Runtime.load(rt, """
      rule announce-once {
        when READY unless $announced {
          log "Ready for work"
          set announced = true
        }
      }
      """)

    assert logs(rt, "READY") == ["Ready for work"]
    assert logs(rt, "READY") == []
    assert logs(rt, "READY") == []
  end

  test "chapter 2 operation order and chapter 3 eager evaluation are observable" do
    source = """
    rule order {
      when GO {
        [PROBE::record "statement"]
        let answer = [PROBE::record "value"]
        let ignored = false AND [PROBE::record "eager"]
        log @answer
      }
    }
    """

    assert {:ok, results} =
             Anemos.run(source,
               event: "GO",
               modules: %{"PROBE" => Probe},
               context_data: %{"recipient" => self()}
             )

    assert_receive {:called, first}
    assert_receive {:called, second}
    assert_receive {:called, third}
    assert [first, second, third] == ["value", "eager", "statement"]
    assert "statement" in results
    assert %{type: :log, value: "value"} in results
  end

  defp cli(example, args) do
    Mix.Tasks.Anemos.Run.execute([Path.join(@manual, "examples/#{example}.rule") | args])
  end

  defp logs(rt, event, payload \\ %{}) do
    {:ok, results} = Runtime.dispatch(rt, event, %{context_data: payload})
    assert [] == for({:error, error} <- results, do: error)
    for %{type: :log, value: value} <- results, do: value
  end
end

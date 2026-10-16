# Run from the repository root: mix run docs/manual/examples/workshop.exs
defmodule Tutorial.Alerts do
  use Anemos.Module, name: "ALERT"

  @impl Anemos.Runtime.Module
  def arg_schema("send"), do: [[type: :string], [type: :number]]
  def arg_schema(_verb), do: nil

  verb :send, fn [sensor, celsius], _context ->
    receipt = %{sensor: sensor, celsius: celsius}
    Agent.update(Tutorial.AlertSink, &(&1 ++ [receipt]))
    {:ok, receipt}
  end
end

alias Anemos.Runtime

{:ok, sink} = Agent.start_link(fn -> [] end, name: Tutorial.AlertSink)

try do
  {:ok, runtime} =
    Runtime.start_link(name: :manual_workshop, modules: %{"ALERT" => Tutorial.Alerts})

  try do
    source = File.read!(Path.join(__DIR__, "workshop.rule"))
    :ok = Runtime.load(:manual_workshop, source, policy: "workshop.rule")

    logs = fn event, payload, path ->
      {:ok, results} =
        Runtime.dispatch(:manual_workshop, event, %{context_path: path, context_data: payload})

      [] = for {:error, error} <- results, do: error
      for %{type: :log, value: value} <- results, do: value
    end

    path = "workshop.bench.sensor"
    [0] = logs.("REPORT", %{}, path)
    [] = logs.("TEMPERATURE", %{"sensor" => "bench_a", "celsius" => 22}, path)

    [%{sensor: "bench_a", celsius: 31}] =
      logs.("TEMPERATURE", %{"sensor" => "bench_a", "celsius" => 31}, path)

    ["Unknown sensor"] =
      logs.("TEMPERATURE", %{"sensor" => "unknown", "celsius" => 35}, path)

    [] = logs.("MUTE", %{}, path)
    [] = logs.("TEMPERATURE", %{"sensor" => "bench_a", "celsius" => 40}, path)
    [] = logs.("UNMUTE", %{}, path)

    [%{sensor: "bench_b", celsius: 32}] =
      logs.("TEMPERATURE", %{"sensor" => "bench_b", "celsius" => 32}, path)

    [2] = logs.("REPORT", %{}, path)

    [] = logs.("TEMPERATURE", %{"sensor" => "bench_a", "celsius" => 50}, "garden.bench")

    [%{sensor: "bench_a", celsius: 31}, %{sensor: "bench_b", celsius: 32}] =
      Agent.get(sink, & &1)

    :ok = Runtime.load(:manual_workshop, source, policy: "workshop.rule")
    [2] = logs.("REPORT", %{}, path)
    changed = String.replace(source, "Unknown sensor", "Unrecognized sensor")
    :ok = Runtime.load(:manual_workshop, changed, policy: "workshop.rule")
    [0] = logs.("REPORT", %{}, path)

    :ok = Runtime.unload(:manual_workshop, "workshop.rule")
    [] = logs.("REPORT", %{}, path)

    IO.puts("Workshop scenario passed.")
  after
    Supervisor.stop(runtime)
  end
after
  Agent.stop(sink)
end

# Run from the repository root: mix run docs/manual/examples/walkthrough.exs
alias Anemos.Runtime

{:ok, pid} = Runtime.start_link(name: :manual_walkthrough)

try do
  for file <- ["counter", "batch", "users"] do
    source = File.read!(Path.join(__DIR__, file <> ".rule"))
    :ok = Runtime.load(:manual_walkthrough, source, policy: file <> ".rule")
  end

  logs = fn event, payload ->
    {:ok, results} =
      Runtime.dispatch(:manual_walkthrough, event, %{context_data: payload})

    [] = for {:error, error} <- results, do: error
    for %{type: :log, value: value} <- results, do: value
  end

  [1] = logs.("MOTION", %{})
  [2] = logs.("MOTION", %{})
  [] = logs.("RESET", %{})
  [1] = logs.("MOTION", %{})
  [22] = logs.("BATCH", %{"values" => [-1, 2, -3, 4, 5]})
  ["Allowed"] = logs.("LOGIN", %{"user" => "alice"})
  ["Denied"] = logs.("LOGIN", %{"user" => "mallory"})

  IO.puts("Counter, pipeline, and dataset examples passed.")
after
  Supervisor.stop(pid)
end

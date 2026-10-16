# Run from the repository root: mix run docs/manual/examples/data_models.exs
defmodule Tutorial.Words do
  @behaviour Anemos.DataModel

  @impl true
  def keyword, do: "words"

  @impl true
  def parse(raw), do: {:ok, String.split(raw)}

  @impl true
  def eval(words, _context), do: {:ok, words}

  @impl true
  def transduce(words, _shape, "resource.transducer.upcase") do
    {:ok, Enum.map(words, &String.upcase/1)}
  end

  def transduce(_words, _shape, _name), do: {:error, :not_supported}
end

defmodule Tutorial.Greeter do
  @behaviour Anemos.DataModel

  @impl true
  def keyword, do: "greeter"

  @impl true
  def parse(raw), do: {:ok, String.trim(raw)}

  @impl true
  def eval(prefix, %{bindings: %{"name" => name}}) do
    {:ok, %{"line" => prefix <> " " <> name}}
  end

  @impl true
  def transduce(_data, _shape, _name), do: {:error, :not_supported}
end

alias Anemos.Runtime

{:ok, pid} = Runtime.start_link(name: :manual_data_models)

try do
  :ok = Runtime.register_data_model(:manual_data_models, Tutorial.Words)
  :ok = Runtime.register_data_model(:manual_data_models, Tutorial.Greeter)

  for file <- ["words", "query"] do
    source = File.read!(Path.join(__DIR__, file <> ".rule"))
    :ok = Runtime.load(:manual_data_models, source, policy: file <> ".rule")
  end

  logs = fn event, payload ->
    {:ok, results} = Runtime.dispatch(:manual_data_models, event, %{context_data: payload})
    [] = for {:error, error} <- results, do: error
    for %{type: :log, value: value} <- results, do: value
  end

  ["Crew member"] = logs.("LOGIN", %{"user" => "alice"})
  ["Loud crew member"] = logs.("LOGIN", %{"user" => "ALICE"})
  ["hello Ada"] = logs.("ARRIVAL", %{"visitor" => "Ada"})

  IO.puts("Format, transclusion, and query examples passed.")
after
  Supervisor.stop(pid)
end

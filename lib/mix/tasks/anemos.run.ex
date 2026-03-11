defmodule Mix.Tasks.Anemos.Run do
  @moduledoc """
  Parse and execute a .rule file against a given event.

  ## Usage

      mix anemos.run priv/examples/garage-lights.rule --event SENSOR_MOTION_DETECTED
  """

  use Mix.Task

  @shortdoc "Parse and execute a .rule file"

  @impl true
  def run([]) do
    Mix.shell().error("Usage: mix anemos.run <file.rule> --event EVENT_NAME")
  end

  def run([file | args]) do
    Mix.Task.run("app.start")
    source = File.read!(file)
    event = extract_event(args)

    case Anemos.run(source, event: event) do
      {:ok, results} ->
        Enum.each(results, fn op -> Mix.shell().info(inspect(op)) end)

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
    end
  end

  defp extract_event(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--event", event] -> event
      _ -> nil
    end) || Mix.raise("--event flag is required")
  end
end

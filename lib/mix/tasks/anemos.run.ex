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

    Mix.shell().info("Parsing #{file}...")

    case Anemos.run(source, event: event) do
      {:ok, []} ->
        Mix.shell().info("No rules matched event #{event}.")

      {:ok, results} ->
        Mix.shell().info("Dispatched #{event} -- #{length(results)} operation(s):\n")

        Enum.each(results, fn
          %{module: mod, verb: verb, args: args} ->
            Mix.shell().info("  [#{mod}::#{verb} #{Enum.map_join(args, " ", &inspect/1)}]")

          %{type: :log, value: value} ->
            Mix.shell().info("  log #{inspect(value)}")

          %{type: :emit, value: value} = op ->
            dest = if op[:destination], do: " to #{op[:destination]}", else: ""
            label = if op[:label], do: " as #{op[:label]}", else: ""
            Mix.shell().info("  emit #{inspect(value)}#{dest}#{label}")

          %{type: :demand, capability: cap} ->
            Mix.shell().info("  demand #{cap}")

          %{type: :set, name: name, value: value} ->
            Mix.shell().info("  set #{name} = #{inspect(value)}")

          other ->
            Mix.shell().info("  #{inspect(other)}")
        end)

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

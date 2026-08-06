defmodule Mix.Tasks.Anemos.Run do
  @moduledoc """
  Parse and execute a `.rule` file against a given event.

      mix anemos.run priv/examples/garage-lights.rule \\
        --event SENSOR_MOTION_DETECTED --context garage.motion.sensor

  ## Options

    * `--event`, `-e` — event name to dispatch (required)
    * `--context`, `-c` — the context path the caller occupies. `context`
      is a security boundary and fails closed, so a rule wrapped in
      `context "garage"` is unreachable until the caller says it is
      standing in `garage` or beneath it. Omitting this is not "run
      everything"; it is "I decline to say", and a declared boundary
      refuses that.
    * `--context-data KEY=VALUE` — external data that `?var` resolves
      against. Repeatable. This is a *different* thing from `--context`:
      one is where the caller stands, the other is what it brought with it.
    * `--stub-modules` — also register `Anemos.example_modules/0`, the
      demonstration doubles for `PDF`, `STRING`, `INFRA`, `SECRET` and
      `EVENT` that `priv/examples/` needs. Off by default: see
      `Anemos.example_modules/0` for why a `SECRET` double must be asked
      for rather than inherited.
    * `--help`, `-h` — print this usage summary.

  ## Exit status

  `0` only when every operation succeeded. `1` on a usage error, an
  unreadable file, a refused load, a parse or compile failure, or any
  operation that returned an error — so the task can gate a script or a CI
  step.

  ## The load is gated

  The source goes through the same trust boundary as
  `Anemos.Runtime.load/3` — the `:max_policy_bytes` ceiling and the
  configured `Anemos.Runtime.LoadAuthority` (A-59). A refusal is reported
  as such, named as the boundary rather than as a broken rule file, and
  exits `1`. The default authority permits everything, so this changes
  nothing until an operator configures one.

  An empty result is reported as one of three distinct outcomes, because
  they call for three different fixes: nothing subscribed to the event
  (check the event name), something subscribed but the context boundary
  denied it (pass `--context`), or a rule ran and every branch was false
  (check the guards and the data). The previous single message, "No rules
  matched", was wrong for all three — it describes zero *operations*.
  """

  use Mix.Task

  @shortdoc "Parse and execute a .rule file"

  @switches [
    event: :string,
    context: :string,
    context_data: :keep,
    stub_modules: :boolean,
    help: :boolean
  ]

  @aliases [e: :event, c: :context, h: :help]

  @impl true
  def run(argv) do
    {status, lines} = execute(argv)

    Enum.each(lines, fn
      {:error, text} -> Mix.shell().error(text)
      {:info, text} -> Mix.shell().info(text)
    end)

    # `exit({:shutdown, n})` is the Mix idiom for a non-zero status: it sets
    # the exit code without printing an exception the user did not cause.
    if status == :error, do: exit({:shutdown, 1})
  end

  @doc """
  The whole task minus the printing and the exit.

  Returns `{:ok | :error, [{:info | :error, String.t()}]}`. Split out so
  the CLI's behaviour — flag parsing, exit status, every message it can
  emit — is testable without capturing IO or halting the VM. The absence
  of that seam is a large part of why these defects survived.
  """
  @spec execute([String.t()]) :: {:ok | :error, [{:info | :error, String.t()}]}
  def execute(argv) do
    case OptionParser.parse(argv, strict: @switches, aliases: @aliases) do
      {opts, positional, []} -> dispatch(opts, positional)
      {_opts, _positional, invalid} -> {:error, invalid_flags(invalid)}
    end
  end

  # --- Private ---

  defp dispatch(opts, positional) do
    cond do
      opts[:help] -> {:ok, [{:info, usage()}]}
      positional == [] -> {:error, [{:error, "No rule file given.\n\n" <> usage()}]}
      opts[:event] in [nil, ""] -> {:error, [{:error, "--event is required.\n\n" <> usage()}]}
      true -> load_and_run(hd(positional), opts)
    end
  end

  defp load_and_run(file, opts) do
    case File.read(file) do
      {:ok, source} -> execute_source(source, file, opts)
      {:error, posix} -> {:error, [{:error, read_error(file, posix)}]}
    end
  end

  defp execute_source(source, file, opts) do
    Mix.Task.run("app.start")

    run_opts =
      [
        event: opts[:event],
        context_path: opts[:context],
        context_data: parse_context_data(opts)
      ] ++ stub_modules(opts)

    case Anemos.run_report(source, run_opts) do
      {:ok, report} -> report_lines(report, file)
      {:error, reason} -> {:error, [{:error, failure_line(reason, file)}]}
    end
  end

  # A refusal is not a broken rule file, and saying "Could not run" for it
  # sends the author to look for a syntax error that is not there. It is
  # the trust boundary (A-59) declining to compile the source, so it names
  # the boundary and points at what an author or operator can change.
  defp failure_line(%Comn.Errors.ErrorStruct{code: "anemos.runtime/load_denied"} = err, file) do
    # `err.message`, not `describe/1`: the registry's `field` and `:auth`
    # category are operator correlation fields, and rendering them here
    # tails the sentence with "(at source) (auth)" in front of someone
    # trying to work out why their file will not run. The framing below
    # already says everything those two encode.
    "Refused to load #{file}: " <>
      err.message <>
      "\n\nThis is the load trust boundary, not a problem with the rule file. " <>
      "The load authority is `config :anemos, :load_authority` " <>
      "(currently #{inspect(Anemos.Runtime.LoadAuthority.configured())}) and the size " <>
      "ceiling is `config :anemos, :max_policy_bytes` " <>
      "(currently #{Anemos.Runtime.LoadAuthority.max_bytes()} bytes)."
  end

  defp failure_line(reason, file) do
    "Could not run #{file}: " <> describe(reason)
  end

  defp stub_modules(opts) do
    if opts[:stub_modules], do: [modules: Anemos.example_modules()], else: []
  end

  # `:keep` collects every `--context-data` occurrence, so the flag is
  # repeatable. A pair without `=` is a usage mistake worth naming, but the
  # value may itself contain `=`, so split only on the first.
  defp parse_context_data(opts) do
    for {:context_data, pair} <- opts, into: %{} do
      case String.split(pair, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, ""}
      end
    end
  end

  defp report_lines(report, file) do
    header = {:info, "Parsed #{file}."}

    case {report.operations, report.errors} do
      {[], _} ->
        {:ok, [header, {:info, empty_reason(report)}]}

      {ops, []} ->
        {:ok, [header, {:info, summary(report, ops)} | Enum.map(ops, &operation/1)]}

      {ops, errs} ->
        {:error,
         [header, {:info, summary(report, ops)} | Enum.map(ops, &operation/1)] ++
           failure_note(errs)}
    end
  end

  defp summary(report, ops) do
    "Dispatched #{report.event} -- #{length(ops)} operation(s):\n"
  end

  defp failure_note(errs) do
    [{:error, "\n#{length(errs)} operation(s) failed."}]
  end

  # The three states the old "No rules matched" collapsed into one.
  defp empty_reason(%{subscribed: 0} = report) do
    "No rule subscribes to event #{report.event}. Check the event name against the `when` clauses in the file."
  end

  defp empty_reason(%{reachable: 0} = report) do
    "#{report.subscribed} rule(s) subscribe to #{report.event}, but none is reachable from " <>
      describe_context(report.context_path) <>
      ". `context` is a boundary and fails closed — pass --context with the path you are standing in."
  end

  defp empty_reason(report) do
    "#{report.reachable} rule(s) ran for #{report.event} and produced no operations — " <>
      "every branch evaluated false. Check the guards and the --context-data they read."
  end

  defp describe_context(nil), do: "an unnamed context (no --context given)"
  defp describe_context(path), do: "context #{inspect(path)}"

  defp operation({:error, reason}), do: {:error, "  ! " <> describe(reason)}

  defp operation(%{module: mod, verb: verb, args: args}) do
    {:info, "  [#{mod}::#{verb} #{Enum.map_join(args, " ", &inspect/1)}]"}
  end

  defp operation(%{type: :log, value: value}), do: {:info, "  log #{inspect(value)}"}

  defp operation(%{type: :emit, value: value} = op) do
    emit_type = if op[:emit_type], do: "#{op[:emit_type]} ", else: ""
    dest = if op[:destination], do: " to #{inspect(op[:destination])}", else: ""
    label = if op[:label], do: " as #{op[:label]}", else: ""
    {:info, "  #{emit_type}emit #{inspect(value)}#{dest}#{label}"}
  end

  defp operation(%{type: :demand, capability: cap}), do: {:info, "  demand #{cap}"}
  defp operation(other), do: {:info, "  #{inspect(other)}"}

  @doc """
  Renders one error for a policy author.

  `Comn.Errors.ErrorStruct` carries `request_id` and `trace_id` for
  correlating across services. Those are operator fields; `inspect/1` on
  the struct — which is what the old fallback did — put them in front of
  someone trying to fix a rule file, alongside every other nil field.

  ## Examples

      iex> err = Comn.Errors.ErrorStruct.new("anemos.runtime/unknown_module", nil, "Module PDF not found in registry")
      iex> Mix.Tasks.Anemos.Run.describe(%{err | trace_id: "abc123"})
      "Module PDF not found in registry (anemos.runtime/unknown_module)"

      iex> Mix.Tasks.Anemos.Run.describe("Unexpected token at line 3")
      "Unexpected token at line 3"
  """
  @spec describe(term()) :: String.t()
  def describe(%Comn.Errors.ErrorStruct{} = err) do
    [err.message, field(err.field), reason(err.reason), suggestion(err.suggestion)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def describe({:error, reason}), do: describe(reason)
  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: inspect(reason)

  defp field(nil), do: nil
  defp field(field), do: "(at #{field})"

  defp reason(nil), do: nil
  defp reason(reason), do: "(#{reason})"

  defp suggestion(nil), do: nil
  defp suggestion(text), do: "-- #{text}"

  defp read_error(file, :enoent) do
    "No such rule file: #{file}"
  end

  defp read_error(file, :eisdir), do: "#{file} is a directory, not a rule file."
  defp read_error(file, :eacces), do: "Permission denied reading #{file}"
  defp read_error(file, posix), do: "Could not read #{file}: #{:file.format_error(posix)}"

  defp invalid_flags(invalid) do
    names = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
    [{:error, "Unrecognised option(s): #{names}\n\n" <> usage()}]
  end

  defp usage do
    """
    Usage: mix anemos.run <file.rule> --event EVENT_NAME [options]

      -e, --event NAME        Event to dispatch. Required.
      -c, --context PATH      Context path the caller occupies. Rules wrapped in a
                              `context` block are unreachable without it.
          --context-data K=V  External data for `?var` lookups. Repeatable.
          --stub-modules      Register the example doubles (PDF, STRING, INFRA,
                              SECRET, EVENT) that priv/examples/ needs.
      -h, --help              Show this message.

    Exits 0 only when every operation succeeded.
    """
  end
end

defmodule Mix.Tasks.Anemos.RunTest do
  @moduledoc """
  The Mix task had no tests, which is a large part of why A-53 and the A-30
  CLI defects survived: every one of them is visible in the first line of
  output, and nothing ever looked.

  These exercise `execute/1` — the task minus the printing and the exit —
  so both the exit status and the exact message are assertable.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Anemos.Run

  @garage "priv/examples/garage-lights.rule"
  @garage_context "garage.motion.sensor"

  defp text(lines), do: Enum.map_join(lines, "\n", fn {_level, line} -> line end)

  defp write_rule(source) do
    path =
      Path.join(System.tmp_dir!(), "anemos_run_test_#{System.unique_integer([:positive])}.rule")

    File.write!(path, source)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "usage errors" do
    test "--help prints usage and succeeds" do
      assert {:ok, lines} = Run.execute(["--help"])
      assert text(lines) =~ "Usage: mix anemos.run"
      assert text(lines) =~ "--context-data"
    end

    test "-h is accepted as an alias" do
      assert {:ok, lines} = Run.execute(["-h"])
      assert text(lines) =~ "Usage: mix anemos.run"
    end

    test "no arguments at all fails rather than printing a bare usage line" do
      assert {:error, lines} = Run.execute([])
      assert text(lines) =~ "No rule file given"
    end

    test "a missing --event fails and says so" do
      assert {:error, lines} = Run.execute([@garage])
      assert text(lines) =~ "--event is required"
    end

    # The hand-rolled chunk_every/4 scan this replaced silently ignored any
    # flag it did not recognise, so a typo did nothing and said nothing.
    test "an unrecognised flag is named rather than ignored" do
      assert {:error, lines} = Run.execute([@garage, "--evnt", "EV"])
      assert text(lines) =~ "Unrecognised option(s): --evnt"
      assert text(lines) =~ "Usage: mix anemos.run"
    end

    test "a mistyped filename reports the path, not a stacktrace" do
      assert {:error, lines} = Run.execute(["priv/examples/no-such.rule", "--event", "EV"])
      assert text(lines) =~ "No such rule file: priv/examples/no-such.rule"
    end

    test "a directory given as a rule file is reported as such" do
      assert {:error, lines} = Run.execute(["priv/examples", "--event", "EV"])
      assert text(lines) =~ "is a directory"
    end
  end

  describe "--context (A-53)" do
    test "a context-scoped rule is unreachable without --context" do
      assert {:ok, lines} = Run.execute([@garage, "--event", "SENSOR_MOTION_DETECTED"])
      out = text(lines)

      assert out =~ "1 rule(s) subscribe to SENSOR_MOTION_DETECTED"
      assert out =~ "no --context given"
      # The old message claimed nothing matched, which was the one reading
      # that told the user to go looking in the wrong place.
      refute out =~ "No rules matched"
    end

    test "--context admits the rule and the operation runs" do
      argv = [@garage, "--event", "SENSOR_MOTION_DETECTED", "--context", @garage_context]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ ~s([DEVICE::set "garage.lights" "on"])
    end

    test "-c is accepted as an alias for --context" do
      argv = [@garage, "-e", "SENSOR_MOTION_DETECTED", "-c", @garage_context]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ "DEVICE::set"
    end

    test "a sibling context does not get in" do
      argv = [@garage, "--event", "SENSOR_MOTION_DETECTED", "--context", "garageband.amp"]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ "none is reachable"
      assert text(lines) =~ ~s(context "garageband.amp")
    end

    test "a context beneath the declared one is admitted" do
      argv = [
        @garage,
        "--event",
        "SENSOR_MOTION_DETECTED",
        "--context",
        @garage_context <> ".zone1"
      ]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ "DEVICE::set"
    end
  end

  describe "--context-data" do
    test "supplies values that ?var resolves against" do
      path = write_rule(~S|rule r { when EV { log ?greeting } }|)

      assert {:ok, lines} =
               Run.execute([path, "--event", "EV", "--context-data", "greeting=hello"])

      assert text(lines) =~ ~s(log "hello")
    end

    test "is repeatable" do
      path = write_rule(~S|rule r { when EV { log ?a log ?b } }|)
      argv = [path, "--event", "EV", "--context-data", "a=1", "--context-data", "b=2"]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ ~s(log "1")
      assert text(lines) =~ ~s(log "2")
    end

    test "a value containing = is kept whole" do
      path = write_rule(~S|rule r { when EV { log ?token } }|)
      argv = [path, "--event", "EV", "--context-data", "token=a=b=c"]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ ~s(log "a=b=c")
    end

    test "is distinct from --context: data alone does not open the boundary" do
      argv = [@garage, "--event", "SENSOR_MOTION_DETECTED", "--context-data", "x=1"]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ "none is reachable"
    end
  end

  describe "the three empty-result states (A-30)" do
    test "nothing subscribed to the event" do
      argv = [@garage, "--event", "NO_SUCH_EVENT", "--context", @garage_context]

      assert {:ok, lines} = Run.execute(argv)
      assert text(lines) =~ "No rule subscribes to event NO_SUCH_EVENT"
    end

    test "subscribed but denied by the context boundary" do
      assert {:ok, lines} = Run.execute([@garage, "--event", "SENSOR_MOTION_DETECTED"])
      assert text(lines) =~ "fails closed"
    end

    test "ran, but every branch was false" do
      path = write_rule(~S|rule r { when EV { if ?flag eq "on" { log "fired" } } }|)

      assert {:ok, lines} = Run.execute([path, "--event", "EV"])
      out = text(lines)

      assert out =~ "produced no operations"
      assert out =~ "every branch evaluated false"
    end
  end

  describe "exit status" do
    test "a run in which every operation succeeded reports :ok" do
      argv = [@garage, "--event", "SENSOR_MOTION_DETECTED", "--context", @garage_context]
      assert {:ok, _} = Run.execute(argv)
    end

    test "an operation that failed makes the whole run fail" do
      path = write_rule(~S|rule r { when EV { [NOSUCHMODULE::act] } }|)

      assert {:error, lines} = Run.execute([path, "--event", "EV"])
      out = text(lines)

      assert out =~ "Module NOSUCHMODULE not found in registry"
      assert out =~ "1 operation(s) failed"
    end

    test "a parse error fails rather than succeeding quietly" do
      path = write_rule("rule r {")

      assert {:error, lines} = Run.execute([path, "--event", "EV"])
      assert text(lines) =~ "Could not run"
    end
  end

  describe "error rendering" do
    test "an ErrorStruct is rendered for a policy author, not inspected" do
      path = write_rule(~S|rule r { when EV { [NOSUCHMODULE::act] } }|)

      assert {:error, lines} = Run.execute([path, "--event", "EV"])
      out = text(lines)

      # inspect/1 on the struct dumped these at the user alongside every
      # other nil field. They are operator correlation ids, not something a
      # rule author can act on.
      refute out =~ "request_id"
      refute out =~ "trace_id"
      refute out =~ "ErrorStruct"
    end

    test "describe/1 keeps message, field and suggestion and drops the rest" do
      err =
        Comn.Errors.ErrorStruct.new(
          "validation",
          "module",
          "Module PDF not found",
          "Pass --stub-modules"
        )

      rendered = Run.describe(%{err | trace_id: "trace-abc", request_id: "req-1"})

      assert rendered =~ "Module PDF not found"
      assert rendered =~ "(at module)"
      assert rendered =~ "-- Pass --stub-modules"
      refute rendered =~ "trace-abc"
      refute rendered =~ "req-1"
    end

    test "describe/1 passes a plain string through unchanged" do
      assert Run.describe("Unexpected token at line 3") == "Unexpected token at line 3"
    end
  end

  describe "--stub-modules" do
    test "is required before the example doubles resolve" do
      path = write_rule(~S|rule r { when EV { [STRING::slugify "A B"] } }|)

      assert {:error, lines} = Run.execute([path, "--event", "EV"])
      assert text(lines) =~ "Module STRING not found in registry"
    end

    test "registers them when asked" do
      path = write_rule(~S|rule r { when EV { [STRING::slugify "Draft Report v2"] } }|)

      assert {:ok, lines} = Run.execute([path, "--event", "EV", "--stub-modules"])
      assert text(lines) =~ "draft-report-v2"
    end
  end
end

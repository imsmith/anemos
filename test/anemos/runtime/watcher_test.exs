defmodule Anemos.Runtime.WatcherTest do
  @moduledoc """
  A directory of `.rule` files kept deployed: save deploys, delete unloads,
  a broken save leaves the running version alone.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Anemos.Runtime
  alias Anemos.Runtime.Watcher

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} = context do
    name = :"w_#{:erlang.phash2(context.test)}"
    start_supervised!({Runtime, name: name})
    watcher = start_supervised!({Watcher, runtime: name, dir: dir, interval_ms: :manual})
    %{rt: name, watcher: watcher}
  end

  defp write(dir, file, source) do
    path = Path.join(dir, file)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source)
  end

  defp logs(rt, event) do
    {:ok, results} = Runtime.dispatch(rt, event)
    for %{type: :log, value: value} <- results, do: value
  end

  test "a new file is deployed under its relative path", %{rt: rt, watcher: w, tmp_dir: dir} do
    write(dir, "garage/lights.rule", ~s|rule a { when EV { log "a" } }|)
    write(dir, "notes.txt", "not a policy")

    :ok = Watcher.scan(w)

    assert logs(rt, "EV") == ["a"]
    assert Watcher.status(w) == %{"garage/lights.rule" => :ok}
    assert [%{id: "garage/lights.rule"}] = Runtime.policies(rt)
  end

  test "an edit is deployed, and a rule it did not touch keeps its state",
       %{rt: rt, watcher: w, tmp_dir: dir} do
    counter = ~s|rule count { when TICK { log $seen\n set seen = "yes" } }\n|
    write(dir, "p.rule", counter <> ~s|rule a { when EV { log "one" } }|)
    :ok = Watcher.scan(w)
    logs(rt, "TICK")

    write(dir, "p.rule", counter <> ~s|rule a { when EV { log "two" } }|)
    :ok = Watcher.scan(w)

    assert logs(rt, "EV") == ["two"]
    assert logs(rt, "TICK") == ["yes"]
  end

  test "a broken save keeps the running version, and the next good save lands",
       %{rt: rt, watcher: w, tmp_dir: dir} do
    write(dir, "p.rule", ~s|rule a { when EV { log "good" } }|)
    :ok = Watcher.scan(w)

    write(dir, "p.rule", "rule a { when")

    log = capture_log(fn -> :ok = Watcher.scan(w) end)
    assert log =~ "p.rule not deployed, previous version kept"
    assert %{"p.rule" => {:error, _}} = Watcher.status(w)
    assert logs(rt, "EV") == ["good"]

    # The same broken content is not retried or logged again.
    assert capture_log(fn -> :ok = Watcher.scan(w) end) == ""

    write(dir, "p.rule", ~s|rule a { when EV { log "fixed" } }|)
    :ok = Watcher.scan(w)

    assert logs(rt, "EV") == ["fixed"]
    assert Watcher.status(w) == %{"p.rule" => :ok}
  end

  test "a deleted file is unloaded", %{rt: rt, watcher: w, tmp_dir: dir} do
    write(dir, "p.rule", ~s|rule a { when EV { log "a" } }|)
    :ok = Watcher.scan(w)

    File.rm!(Path.join(dir, "p.rule"))
    :ok = Watcher.scan(w)

    assert logs(rt, "EV") == []
    assert Runtime.policies(rt) == []
    assert Watcher.status(w) == %{}
  end

  test "an unchanged file is not redeployed", %{rt: rt, watcher: w, tmp_dir: dir} do
    write(dir, "p.rule", ~s|rule a { when EV { log "a" } }|)
    :ok = Watcher.scan(w)

    # Unloaded behind the watcher's back: a redeploy would bring it back.
    :ok = Runtime.unload(rt, "p.rule")
    :ok = Watcher.scan(w)

    assert logs(rt, "EV") == []
  end

  describe "signatures" do
    setup do
      on_exit(fn -> Application.delete_env(:anemos, :load_authority) end)
      Application.put_env(:anemos, :load_authority, Anemos.Runtime.LoadAuthority.Signed)
      :ok
    end

    @signed ~s|rule watched {\n  signed_by :operator\n  when EV { log "signed" }\n}\n|

    test "a .sig beside the file is the detached signature, and adding it is a change",
         %{tmp_dir: dir} do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      key = %Comn.Secrets.Key{algorithm: :ed25519, public: public}

      start_supervised!(
        Supervisor.child_spec({Runtime, name: :w_signed, keyring: %{"operator" => key}},
          id: :signed_runtime
        )
      )

      w =
        start_supervised!(
          Supervisor.child_spec({Watcher, runtime: :w_signed, dir: dir, interval_ms: :manual},
            id: :signed_watcher
          )
        )

      write(dir, "p.rule", @signed)
      capture_log(fn -> :ok = Watcher.scan(w) end)
      assert %{"p.rule" => {:error, _}} = Watcher.status(w)
      assert logs(:w_signed, "EV") == []

      sig = :crypto.sign(:eddsa, :none, @signed, [private, :ed25519])
      write(dir, "p.rule.sig", Base.encode64(sig) <> "\n")
      :ok = Watcher.scan(w)

      assert Watcher.status(w) == %{"p.rule" => :ok}
      assert logs(:w_signed, "EV") == ["signed"]
    end
  end

  test "the runtime's watch: option keeps a directory deployed on its own", %{tmp_dir: dir} do
    write(dir, "p.rule", ~s|rule a { when EV { log "a" } }|)

    start_supervised!(
      Supervisor.child_spec({Runtime, name: :w_opt, watch: dir}, id: :watching_runtime)
    )

    :ok = Watcher.scan(Runtime.watcher_name(:w_opt))
    assert logs(:w_opt, "EV") == ["a"]
  end
end

defmodule Anemos.Runtime.DeployTest do
  @moduledoc """
  A load that names a policy deploys it over whatever was last loaded under
  that name: afterwards the runtime holds what the new version declares and
  nothing the old one declared that the new one does not.

  One test per cell of the table in
  `docs/superpowers/specs/2026-10-02-hot-reload-design.md` §2.
  """
  use ExUnit.Case, async: false

  alias Anemos.Runtime
  alias Anemos.Runtime.{Dispatcher, Scheduler, StoreSupervisor}

  defmodule Feed do
    @moduledoc false
    @behaviour Anemos.Subscribable

    @impl true
    def subscribe(_protocol, uri, callback) do
      ref = make_ref()
      send(:deploy_test_feed, {:subscribed, uri, ref, callback})
      {:ok, ref}
    end

    @impl true
    def unsubscribe(ref) do
      send(:deploy_test_feed, {:unsubscribed, ref})
      :ok
    end
  end

  setup context do
    tag = context.test |> to_string() |> String.replace(~r/\W/, "_")
    name = :"dp_#{:erlang.phash2(tag)}"

    start_supervised!({Runtime, name: name})

    %{
      rt: name,
      dispatcher: :"#{name}.dispatcher",
      scheduler: :"#{name}.scheduler",
      stores: :"#{name}.store_supervisor"
    }
  end

  defp logs(rt, event) do
    {:ok, results} = Runtime.dispatch(rt, event)
    for %{type: :log, value: value} <- results, do: value
  end

  defp deploy!(rt, id, source), do: :ok = Runtime.load(rt, source, policy: id)

  @counter """
  rule count {
    when TICK {
      log $seen
      set seen = "yes"
    }
  }
  """

  describe "rules" do
    test "a rule dropped from the source stops firing", %{rt: rt} do
      deploy!(rt, "p", """
      rule a { when EV { log "a" } }
      rule b { when EV { log "b" } }
      """)

      assert Enum.sort(logs(rt, "EV")) == ["a", "b"]

      deploy!(rt, "p", ~s|rule a { when EV { log "a" } }|)

      assert logs(rt, "EV") == ["a"]
    end

    test "an unchanged rule keeps its state when its neighbour is edited", %{rt: rt} do
      deploy!(rt, "p", @counter <> ~s|rule other { when EV { log "one" } }|)
      assert logs(rt, "TICK") == [nil]
      assert logs(rt, "TICK") == ["yes"]

      # Edited neighbour above it, so the unchanged rule also moves down the file.
      deploy!(rt, "p", ~s|rule other { when EV { log "two" } }\n\n| <> @counter)

      assert logs(rt, "EV") == ["two"]
      assert logs(rt, "TICK") == ["yes"]
    end

    test "a changed rule starts from nothing", %{rt: rt} do
      deploy!(rt, "p", @counter)
      logs(rt, "TICK")
      assert logs(rt, "TICK") == ["yes"]

      deploy!(rt, "p", String.replace(@counter, ~s|"yes"|, ~s|"again"|))

      assert logs(rt, "TICK") == [nil]
      assert logs(rt, "TICK") == ["again"]
    end

    test "deploying the same source twice changes nothing", %{rt: rt} do
      deploy!(rt, "p", @counter)
      logs(rt, "TICK")
      deploy!(rt, "p", @counter)

      assert logs(rt, "TICK") == ["yes"]
    end
  end

  describe "conditions and capabilities" do
    @condition ~s|condition hot { when TEMP { log "c" } }\n|

    test "a condition dropped from the source loses its server", %{rt: rt, stores: stores} do
      deploy!(rt, "p", @condition <> ~s|rule r { when EV { log "r" } }|)
      assert Map.has_key?(StoreSupervisor.snapshot(stores).conditions, "hot")

      deploy!(rt, "p", ~s|rule r { when EV { log "r" } }|)

      assert StoreSupervisor.snapshot(stores).conditions == %{}
      assert Runtime.condition_state(rt, "hot") == nil
    end

    test "an unchanged condition keeps its state", %{rt: rt} do
      deploy!(rt, "p", @condition <> ~s|rule r { when EV { log "one" } }|)
      Runtime.dispatch(rt, "TEMP")
      assert Runtime.condition_state(rt, "hot") == true

      deploy!(rt, "p", ~s|rule r { when EV { log "two" } }\n| <> @condition)

      assert Runtime.condition_state(rt, "hot") == true
    end

    test "a changed condition reads false", %{rt: rt} do
      deploy!(rt, "p", @condition)
      Runtime.dispatch(rt, "TEMP")

      deploy!(rt, "p", String.replace(@condition, ~s|"c"|, ~s|"changed"|))

      assert Runtime.condition_state(rt, "hot") == false
    end

    test "a capability dropped from the source loses its server", %{rt: rt, stores: stores} do
      deploy!(rt, "p", ~s|capability k { on demand { log "k" } }|)
      assert Map.has_key?(StoreSupervisor.snapshot(stores).capabilities, "k")

      deploy!(rt, "p", ~s|rule r { when EV { log "r" } }|)

      assert StoreSupervisor.snapshot(stores).capabilities == %{}
    end
  end

  describe "data blocks" do
    test "a data block dropped from the source is deregistered", %{rt: rt, dispatcher: d} do
      deploy!(rt, "p", "data users { alice }")
      assert Dispatcher.data_member?(d, "users", "alice")

      deploy!(rt, "p", ~s|rule r { when EV { log "r" } }|)

      refute Dispatcher.data_member?(d, "users", "alice")
    end

    test "a live subscription is cancelled when its block goes, and not doubled on redeploy",
         %{rt: rt, dispatcher: d} do
      Process.register(self(), :deploy_test_feed)
      :ok = Dispatcher.register_subscribable(d, "feed", Feed)

      source = """
      data live {
        dynamic {
          subscribe feed "feed://x"
        }
      }
      """

      deploy!(rt, "p", source)
      assert_receive {:subscribed, "feed://x", first, _}

      deploy!(rt, "p", String.replace(source, "feed://x", "feed://y"))
      assert_receive {:unsubscribed, ^first}
      assert_receive {:subscribed, "feed://y", second, _}

      :ok = Runtime.unload(rt, "p")
      assert_receive {:unsubscribed, ^second}
    end

    test "an unchanged subscribed block keeps its feed and what the feed delivered",
         %{rt: rt, dispatcher: d} do
      Process.register(self(), :deploy_test_feed)
      :ok = Dispatcher.register_subscribable(d, "feed", Feed)

      source = """
      data live {
        dynamic {
          subscribe feed "feed://x"
        }
      }
      """

      deploy!(rt, "p", source)
      assert_receive {:subscribed, "feed://x", _ref, deliver}
      deliver.(["alice"])
      assert Dispatcher.data_member?(d, "live", "alice")

      deploy!(rt, "p", source <> ~s|rule other { when EV { log "x" } }|)

      refute_receive {:unsubscribed, _}
      refute_receive {:subscribed, _, _, _}
      assert Dispatcher.data_member?(d, "live", "alice")
    end

    test "a data block another policy declares is refused", %{rt: rt, dispatcher: d} do
      deploy!(rt, "p", "data users { alice }")

      assert {:error, %{message: message}} = Runtime.load(rt, "data users { bob }", policy: "q")
      assert message =~ ~s|data block "users"|

      assert Dispatcher.data_member?(d, "users", "alice")
    end
  end

  describe "schedules" do
    defp armed(scheduler), do: scheduler |> Scheduler.schedules() |> Enum.map(& &1.event_name)

    test "an at block dropped from the source is disarmed", %{rt: rt, scheduler: s} do
      deploy!(rt, "p", ~s|rule r { at 08:00 { log "t" } }|)
      assert [_] = armed(s)

      deploy!(rt, "p", ~s|rule r { when EV { log "r" } }|)

      assert armed(s) == []
    end

    test "a time another policy still declares stays armed", %{rt: rt, scheduler: s} do
      deploy!(rt, "p", ~s|rule r { at 08:00 { log "t" } }|)
      deploy!(rt, "q", ~s|rule q { at 08:00 { log "t" } }|)

      :ok = Runtime.unload(rt, "p")

      assert [_] = armed(s)
    end

    test "a time one policy drops as another picks it up ends up armed", %{rt: rt, scheduler: s} do
      deploy!(rt, "p", ~s|rule r { at 08:00 { log "t" } }|)

      # Interleaved as two concurrent callers could be: q is recorded while
      # p's timer is still armed, then p's drop is processed.
      d = :"#{rt}.dispatcher"
      {:ok, ast} = Anemos.Parser.parse(~s|rule q { at 08:00 { log "t" } }|)
      {:ok, compiled} = Anemos.Compiler.compile(ast)
      :ok = Dispatcher.deploy(d, "q", compiled, %{})
      deploy!(rt, "p", ~s|rule r { when EV { log "r" } }|)

      assert [_] = armed(s)
    end

    test "a time that does not exist is an inert declaration, not a crash",
         %{rt: rt, scheduler: s} do
      scheduler = Process.whereis(s)

      assert {:partial, [%{code: "anemos.scheduler/" <> _}]} =
               Runtime.load(rt, ~s|rule r { at 25:99 { log "t" } }|, policy: "p")

      assert Process.whereis(s) == scheduler
      assert armed(s) == []
    end

    test "a schedule that is already armed keeps its timer", %{rt: rt, scheduler: s} do
      source = ~s|rule r { at 08:00 { log "t" } }|
      deploy!(rt, "p", source)
      timers = :sys.get_state(s).timers

      deploy!(rt, "p", source <> ~s|\nrule extra { when EV { log "x" } }|)

      assert :sys.get_state(s).timers == timers
    end
  end

  describe "identity" do
    test "policies are independent: deploying one leaves the other alone", %{rt: rt} do
      deploy!(rt, "p", ~s|rule a { when EV { log "a" } }|)
      deploy!(rt, "q", ~s|rule b { when EV { log "b" } }|)

      deploy!(rt, "p", ~s|rule c { when EV { log "c" } }|)

      assert Enum.sort(logs(rt, "EV")) == ["b", "c"]
    end

    test "a name another policy declares is refused, and nothing loads", %{rt: rt} do
      deploy!(rt, "p", ~s|rule a { when EV { log "from p" } }|)

      assert {:error, %{message: message}} =
               Runtime.load(
                 rt,
                 ~s|rule a { when EV { log "from q" } }\nrule z { when EV { log "z" } }|,
                 policy: "q"
               )

      assert message =~ ~s|rule "a"|
      assert message =~ ~s|"p"|
      assert logs(rt, "EV") == ["from p"]
      assert Enum.map(Runtime.policies(rt), & &1.id) == ["p"]
    end

    test "a named policy and an anonymous load cannot hold the same name, either way round",
         %{rt: rt} do
      :ok = Runtime.load(rt, ~s|rule anon { when EV { log "anon" } }|)
      deploy!(rt, "p", ~s|rule named { when EV { log "named" } }|)

      assert {:error, %{message: taken}} =
               Runtime.load(rt, ~s|rule anon { when EV { log "stolen" } }|, policy: "q")

      assert taken =~ ~s|rule "anon"|

      assert {:error, %{message: taken}} =
               Runtime.load(rt, ~s|rule named { when EV { log "stolen" } }|)

      assert taken =~ ~s|"p"|

      assert Enum.sort(logs(rt, "EV")) == ["anon", "named"]
    end

    test "a source that does not parse leaves the deployed version running", %{rt: rt} do
      deploy!(rt, "p", ~s|rule a { when EV { log "a" } }|)

      assert {:error, _} = Runtime.load(rt, "rule a { when", policy: "p")

      assert logs(rt, "EV") == ["a"]
    end

    test "unload removes everything the policy declared", %{rt: rt, stores: stores} do
      deploy!(rt, "p", """
      rule a { when EV { log "a" } }
      condition hot { when TEMP { log "c" } }
      capability k { on demand { log "k" } }
      """)

      assert :ok = Runtime.unload(rt, "p")

      assert logs(rt, "EV") == []
      snapshot = StoreSupervisor.snapshot(stores)
      assert snapshot.conditions == %{} and snapshot.capabilities == %{}
      assert Runtime.policies(rt) == []
      assert {:error, %{code: "anemos.runtime/not_loaded"}} = Runtime.unload(rt, "p")
    end

    test "policies lists what each policy declares", %{rt: rt} do
      deploy!(rt, "p", """
      rule a { when EV { log "a" } }
      condition hot { when TEMP { log "c" } }
      capability k { on demand { log "k" } }
      data users { alice }
      """)

      :ok = Runtime.load(rt, ~s|rule anon { when EV { log "x" } }|)

      assert [
               %{
                 id: "p",
                 rules: ["a"],
                 conditions: ["hot"],
                 capabilities: ["k"],
                 data_blocks: ["users"],
                 schedules: []
               },
               %{id: nil, rules: ["anon"]}
             ] = Runtime.policies(rt)
    end

    test "a deployed policy survives a dispatcher restart", %{rt: rt, dispatcher: d} do
      deploy!(rt, "p", ~s|rule a { when EV { log "a" } }|)
      deploy!(rt, "p", ~s|rule b { when EV { log "b" } }|)

      ref = Process.monitor(Process.whereis(d))
      Process.exit(Process.whereis(d), :kill)
      assert_receive {:DOWN, ^ref, _, _, _}
      wait_for(d)

      assert logs(rt, "EV") == ["b"]
    end

    test "a policy name must be a non-empty string", %{rt: rt} do
      assert {:error, %{message: message}} =
               Runtime.load(rt, "rule a { when EV { log 1 } }", policy: "")

      assert message =~ "policy"
    end
  end

  defp wait_for(name, tries \\ 100) do
    cond do
      Process.whereis(name) -> :ok
      tries == 0 -> flunk("#{name} did not restart")
      true -> Process.sleep(10) && wait_for(name, tries - 1)
    end
  end
end

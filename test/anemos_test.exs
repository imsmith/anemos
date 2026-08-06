defmodule AnemosTest do
  @moduledoc false
  use ExUnit.Case

  doctest Anemos
  doctest Anemos.Runtime.Modules.Example
  doctest Anemos.Runtime.Modules.Example.String

  @scoped ~S|rule r { context "garage" { when EV { [DEVICE::set "l" "on"] } } }|

  test "run/2 requires :event option" do
    assert_raise KeyError, fn ->
      Anemos.run("rule x { when E { } }", [])
    end
  end

  describe "run/2 context options" do
    test ":context_path opens a declared boundary" do
      assert {:ok, []} = Anemos.run(@scoped, event: "EV")
      assert {:ok, [%{module: "DEVICE"}]} = Anemos.run(@scoped, event: "EV", context_path: "garage")
    end

    test ":context_path compares segments, not string prefixes" do
      assert {:ok, []} = Anemos.run(@scoped, event: "EV", context_path: "garageband")
    end

    test ":context_data supplies values for ?var" do
      source = ~S|rule r { when EV { log ?who } }|

      assert {:ok, [%{type: :log, value: "world"}]} =
               Anemos.run(source, event: "EV", context_data: %{"who" => "world"})
    end

    test ":context_data merges into an explicitly built :context map" do
      source = ~S|rule r { context "garage" { when EV { log ?who } } }|

      assert {:ok, [%{type: :log, value: "world"}]} =
               Anemos.run(source,
                 event: "EV",
                 context: %{context_path: "garage", context_data: %{"other" => 1}},
                 context_data: %{"who" => "world"}
               )
    end

    test ":modules registrations override the defaults" do
      source = ~S|rule r { when EV { [STRING::slugify "A B"] } }|

      assert {:ok, [{:error, _}]} = Anemos.run(source, event: "EV")
      assert {:ok, ["a-b"]} = Anemos.run(source, event: "EV", modules: Anemos.example_modules())
    end
  end

  describe "run_report/2" do
    # An empty result list has three unrelated causes and the bare list
    # cannot tell them apart, which is what made the CLI's single "No rules
    # matched" message wrong in all three cases.
    test "distinguishes nothing-subscribed from boundary-denied" do
      assert {:ok, unsubscribed} = Anemos.run_report(@scoped, event: "OTHER", context_path: "garage")
      assert {unsubscribed.subscribed, unsubscribed.reachable} == {0, 0}

      assert {:ok, denied} = Anemos.run_report(@scoped, event: "EV")
      assert {denied.subscribed, denied.reachable} == {1, 0}
    end

    test "reports a rule that ran and produced nothing" do
      source = ~S|rule r { when EV { if ?flag eq "on" { log "fired" } } }|

      assert {:ok, report} = Anemos.run_report(source, event: "EV")
      assert {report.subscribed, report.reachable, report.operations} == {1, 1, []}
    end

    test "separates errors from results while keeping operations in order" do
      source = ~S|rule r { when EV { log "first" [NOPE::act] log "last" } }|

      assert {:ok, report} = Anemos.run_report(source, event: "EV")
      assert [%{value: "first"}, {:error, _}, %{value: "last"}] = report.operations
      assert [%{value: "first"}, %{value: "last"}] = report.results
      assert [{:error, _}] = report.errors
    end

    test "carries the context path the caller supplied" do
      assert {:ok, report} = Anemos.run_report(@scoped, event: "EV", context_path: "garage")
      assert report.context_path == "garage"
      assert report.event == "EV"
    end
  end

  describe "example modules" do
    # These are doubles, not implementations. The one that must not answer
    # plausibly is SECRET: a stub that returns something secret-shaped lets
    # a policy run to completion against fake credentials.
    test "are not registered by default" do
      refute Map.has_key?(Anemos.default_modules(), "SECRET")
      refute Map.has_key?(Anemos.default_modules(), "INFRA")
    end

    test "SECRET::unlock returns a self-identifying marker, not key material" do
      source = ~S|rule r { when EV { [SECRET::unlock "some.key"] } }|

      assert {:ok, [result]} = Anemos.run(source, event: "EV", modules: Anemos.example_modules())
      assert result.stub =~ "no secret material"
    end

    test "FILE::extension computes from the path in context data" do
      source = ~S|rule r { when EV { [FILE::extension] } }|

      assert {:ok, ["pdf"]} =
               Anemos.run(source,
                 event: "EV",
                 modules: Anemos.example_modules(),
                 context_data: %{"file" => "/papers/Draft.PDF"}
               )
    end

    test "INFRA::get_ip distinguishes the address family" do
      source = ~S|rule r { when EV { [INFRA::get_ip "eth0" type:ipv6] } }|

      assert {:ok, ["2001:db8::7"]} =
               Anemos.run(source,
                 event: "EV",
                 modules: Anemos.example_modules(),
                 context_data: %{"ip_eth0_ipv4" => "203.0.113.7", "ip_eth0_ipv6" => "2001:db8::7"}
               )
    end
  end

  describe "shipped examples" do
    test "garage-lights runs from its declared context" do
      source = File.read!("priv/examples/garage-lights.rule")

      assert {:ok, [%{module: "DEVICE", verb: "set", args: ["garage.lights", "on"]}]} =
               Anemos.run(source,
                 event: "SENSOR_MOTION_DETECTED",
                 context_path: "garage.motion.sensor"
               )
    end

    test "ddns resolves its let-bound addresses from context data" do
      source = File.read!("priv/examples/ddns.rule")

      assert {:ok, report} =
               Anemos.run_report(source,
                 event: "CONDITION_networkchanged",
                 context_path: "infra.networking.dns",
                 modules: Anemos.example_modules(),
                 context_data: %{
                   "fqdn" => "host.katachora.com",
                   "hostname" => "host",
                   "ip_eth0_ipv4" => "203.0.113.7",
                   "ip_eth0_ipv6" => "2001:db8::7"
                 }
               )

      assert report.errors == []
      assert "203.0.113.7" in report.results
      assert "2001:db8::7" in report.results
    end

    test "every shipped example parses and compiles" do
      for path <- Path.wildcard("priv/examples/*.rule") do
        assert {:ok, ast} = Anemos.Parser.parse(File.read!(path)), "failed to parse #{path}"
        assert {:ok, _} = Anemos.Compiler.compile(ast), "failed to compile #{path}"
      end
    end
  end
end

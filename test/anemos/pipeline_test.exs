defmodule Anemos.PipelineTest do
  use ExUnit.Case

  test "end-to-end: parse → compile → dispatch → observe" do
    input = """
    rule garage-lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }
    """

    assert {:ok, results} = Anemos.run(input, event: "SENSOR_MOTION_DETECTED")
    assert [%{module: "DEVICE", verb: "set", args: ["garage.lights", "on"]}] = results
  end

  test "non-matching event returns empty results" do
    input = """
    rule garage-lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }
    """

    assert {:ok, []} = Anemos.run(input, event: "SOME_OTHER_EVENT")
  end

  test "parse error returns {:error, message}" do
    input = "rule { broken"

    assert {:error, message} = Anemos.run(input, event: "ANYTHING")
    assert is_binary(message)
  end

  test "multi-rule file with specific event only fires matching rules" do
    input = """
    rule lights-on {
      when SENSOR_MOTION_DETECTED {
        [DEVICE::set "garage.lights" "on"]
      }
    }

    rule save-log {
      when FILE_CHANGED {
        [FILE::write "/tmp/log" "changed"]
      }
    }
    """

    assert {:ok, results} = Anemos.run(input, event: "SENSOR_MOTION_DETECTED")
    assert length(results) == 1
    assert [%{module: "DEVICE", verb: "set", args: ["garage.lights", "on"]}] = results

    assert {:ok, results} = Anemos.run(input, event: "FILE_CHANGED")
    assert length(results) == 1
    assert [%{module: "FILE", verb: "write", args: ["/tmp/log", "changed"]}] = results
  end
end

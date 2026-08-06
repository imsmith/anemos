defmodule Anemos.Runtime.DurationTest do
  @moduledoc false
  use ExUnit.Case, async: true

  alias Anemos.Runtime.Duration

  test "milliseconds passthrough" do
    assert Duration.to_ms({500, :ms}) == 500
  end

  test "seconds" do
    assert Duration.to_ms({3, :s}) == 3_000
    assert Duration.to_ms({3, :seconds}) == 3_000
  end

  test "minutes" do
    assert Duration.to_ms({2, :min}) == 120_000
    assert Duration.to_ms({2, :minutes}) == 120_000
  end

  test "hours" do
    assert Duration.to_ms({1, :h}) == 3_600_000
    assert Duration.to_ms({1, :hours}) == 3_600_000
  end

  test "days" do
    assert Duration.to_ms({2, :d}) == 172_800_000
    assert Duration.to_ms({2, :days}) == 172_800_000
  end

  test "unknown unit returns an error tuple rather than raising" do
    assert {:error, {:unknown_duration_unit, :fortnights}} = Duration.to_ms({2, :fortnights})
  end

  test "malformed duration returns an error tuple rather than raising" do
    assert {:error, {:invalid_duration, "5 minutes"}} = Duration.to_ms("5 minutes")
  end

  test "to_ms!/1 returns the integer for known units" do
    assert Duration.to_ms!({2, :min}) == 120_000
  end

  test "to_ms!/1 raises with a readable message for unknown units" do
    assert_raise ArgumentError, ~r/fortnights/, fn -> Duration.to_ms!({2, :fortnights}) end
  end
end

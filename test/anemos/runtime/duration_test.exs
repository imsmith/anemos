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
end

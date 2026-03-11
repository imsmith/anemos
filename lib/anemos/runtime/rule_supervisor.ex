defmodule Anemos.Runtime.RuleSupervisor do
  @moduledoc """
  DynamicSupervisor for rule processes.

  Minimal structure for v0.1.0 — ready to supervise per-rule
  GenServers when stateful rule execution is needed.
  """

  use DynamicSupervisor

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

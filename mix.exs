defmodule Anemos.MixProject do
  @moduledoc false
  use Mix.Project

  def project do
    [
      app: :anemos,
      version: "0.1.0",
      elixir: "~> 1.19",
      package: package(),
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      aliases: aliases(),
      dialyzer: dialyzer()
    ]
  end

  # `mix check` is the single entry point for a developer or a CI runner.
  # It runs cheapest-first so the fastest signal fails first:
  #
  #   1. format --check-formatted  — seconds, no compile needed
  #   2. credo --strict            — ~1s once compiled
  #   3. test                      — ~7s
  #
  # `dialyzer` is deliberately NOT in `mix check`. Its first run builds a PLT
  # over the whole dependency tree (minutes); afterwards it is ~7s, but the
  # cold-start cost makes it a bad fit for an alias people run reflexively.
  # Run it as its own step: `mix dialyzer`.
  defp aliases do
    [
      check: ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp dialyzer do
    [
      # :mix and :ex_unit are not pulled in as runtime deps, so without this
      # Dialyzer reports Mix.shell/0 and Mix.Task.run/1 as unknown functions
      # in lib/mix/tasks/anemos.run.ex.
      plt_add_apps: [:mix, :ex_unit],
      # :unknown is what surfaces @spec references to types that do not exist —
      # it is how the DynamicSupervisor.supervisor/0 specs were caught.
      flags: [:error_handling, :unknown]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp package do
    [
      licenses: ["AGPL-3.0-or-later"],
      files: ~w(lib mix.exs LICENSE README* CLAUDE.md)
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Anemos.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Pinned to a tag rather than a branch: updating comn should be a
      # deliberate act with its own commit, not something a fresh `mix deps.get`
      # does on its own. v0.5.1 is the tip of comn's main at time of writing.
      {:comn, git: "https://github.com/imsmith/comn.git", tag: "v0.5.1"},
      {:nimble_parsec, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end

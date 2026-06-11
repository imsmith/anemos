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
      deps: deps()
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
      {:comn, path: "../comn"},
      {:nimble_parsec, "~> 1.4"},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false}
    ]
  end
end

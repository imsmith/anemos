defmodule Anemos.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Re-discover Comn registries now that Anemos modules are loaded
    Code.ensure_loaded!(Anemos.Runtime.Errors)
    Comn.Errors.Registry.discover()
    Comn.Discovery.discover()

    children = []

    opts = [strategy: :one_for_one, name: Anemos.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

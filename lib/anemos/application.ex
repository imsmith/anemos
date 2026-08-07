defmodule Anemos.Application do
  @moduledoc """
  OTP application callback for Anemos. Starts no interpreter.

  Anemos is a *library* application. Loading it does not bring up an
  interpreter, because there is nothing to bring up: the interpreter starts
  blank and every rule, module, condition and capability is loaded into it at
  runtime. There is no startup configuration to read and therefore no
  supervision tree this callback could construct without inventing policy.

  The supervision tree is host-started. A host that wants an interpreter calls
  `Anemos.Runtime.start_link/1` and places the returned supervisor under its
  own tree, where it can choose the restart strategy and the process names.
  Multiple independent runtimes in one VM are a supported consequence of that
  choice. To read what the system actually runs, read `Anemos.Runtime` — not
  this module.

  What this callback does do is one-shot: it forces `Anemos.Runtime.Errors` to
  load and re-runs `Comn` discovery, so the `Comn` registries see the Anemos
  error definitions and discoverable modules that were not yet loaded when
  `:comn` itself booted. These are idempotent side effects with no process to
  own them, so they are not children.

  `Anemos.Supervisor` is started childless to satisfy the `Application.start/2`
  contract, which must return a supervisor pid. It is a placeholder for
  process-less application state, not an empty slot waiting to be filled.
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Re-discover Comn registries now that Anemos modules are loaded
    Code.ensure_loaded!(Anemos.Runtime.Errors)
    Comn.Errors.Registry.discover()
    Comn.Discovery.discover()

    # Intentionally empty — see the moduledoc. The interpreter is host-started
    # via Anemos.Runtime.start_link/1; this application supervises nothing.
    children = []

    opts = [strategy: :one_for_one, name: Anemos.Supervisor]
    Supervisor.start_link(children, opts)
  end
end

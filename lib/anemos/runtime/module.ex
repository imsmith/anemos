defmodule Anemos.Runtime.Module do
  @moduledoc """
  Behaviour for Anemos runtime modules (DEVICE, FILE, etc.).

  Each module handles verbs dispatched from compiled rule operations.
  """

  @callback handle_verb(verb :: String.t(), args :: list(), context :: map()) ::
              {:ok, any()} | {:error, any()}
end

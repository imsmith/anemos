defmodule Anemos.Runtime.Errors do
  @moduledoc """
  Compile-time error code registry for the Anemos runtime.

  Declares structured error codes following the `namespace/error_name`
  convention. All errors auto-enrich with `Comn.Contexts` when created
  during a dispatch cycle.
  """

  use Comn.Errors.Registry

  register_error "anemos.runtime/handler_crash", :internal,
    message: "Rule handler raised an exception"

  register_error "anemos.runtime/unknown_module", :validation,
    message: "Module not found in registry"

  register_error "anemos.runtime/unknown_verb", :validation,
    message: "Verb not found on module"
end

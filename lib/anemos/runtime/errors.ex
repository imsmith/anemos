defmodule Anemos.Runtime.Errors do
  @moduledoc """
  Compile-time error code registry for the Anemos runtime.

  Declares structured error codes following the `namespace/error_name`
  convention. All errors auto-enrich with `Comn.Contexts` when created
  during a dispatch cycle.
  """

  use Comn.Errors.Registry

  register_error("anemos.runtime/handler_crash", :internal,
    message: "Rule handler raised an exception"
  )

  register_error("anemos.runtime/unknown_module", :validation,
    message: "Module not found in registry"
  )

  register_error("anemos.runtime/unknown_verb", :validation, message: "Verb not found on module")

  register_error("anemos.runtime/event_recursion_limit", :validation,
    message: "Event recursion limit exceeded"
  )

  register_error("anemos.runtime/unknown_capability", :validation,
    message: "Capability not found in registry"
  )

  # `:auth`, not `:validation`: the capability exists and the demand was well
  # formed. The demanding rule was simply standing outside the context the
  # capability declared.
  register_error("anemos.runtime/capability_context_denied", :auth,
    message: "Capability demanded from outside its declared context"
  )

  # `:validation`, not `:auth`: the caller may well be entitled to the verb.
  # The arguments it supplied are not the shape the verb declared it accepts
  # (A-11). Raised by the dispatcher before `handle_verb/3` is reached.
  register_error("anemos.runtime/invalid_argument", :validation,
    message: "Verb argument failed its declared schema"
  )

  # `:auth`: loading policy is the trust boundary (A-12). This is the
  # configured `Anemos.Runtime.LoadAuthority` refusing a load, not a parse
  # or compile failure — those still answer `{:error, reason}` from the
  # parser and compiler as before.
  register_error("anemos.runtime/load_denied", :auth,
    message: "Policy load refused by the configured load authority"
  )
end

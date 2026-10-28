defmodule Anemos.Runtime.Errors do
  @moduledoc """
  Compile-time error code registry for the Anemos runtime.

  Declares structured error codes following the `namespace/error_name`
  convention. All errors auto-enrich with `Comn.Contexts` when created
  during a dispatch cycle.
  """

  use Comn.Errors.Registry

  # A-22. Every error Anemos answers is one of these — `{:error,
  # %Comn.Errors.ErrorStruct{}}` — whichever layer it came from. The lexer,
  # parser and compiler used to answer bare strings, and a caller had
  # nothing to match on but text; the `code` is now the thing to match and
  # the `message` is for a person.

  # `field` is "line:column".
  register_error("anemos.lexer/invalid_token", :validation,
    message: "Source text is not a token of the language"
  )

  register_error("anemos.parser/syntax_error", :validation,
    message: "Source text is not a well-formed policy"
  )

  register_error("anemos.compiler/invalid_policy", :validation,
    message: "The policy parses but cannot be compiled"
  )

  register_error("anemos.runtime/handler_crash", :internal,
    message: "Rule handler raised an exception"
  )

  register_error("anemos.runtime/unknown_module", :validation,
    message: "Module not found in registry"
  )

  register_error("anemos.runtime/unknown_verb", :validation, message: "Verb not found on module")

  # `on` versus `when`: ON_* names are interactions and only interact/3 may
  # raise them; what a host hands interact/3 must be one.
  register_error("anemos.runtime/reserved_event", :validation,
    message: "ON_ names are interactions; raise them with interact/3, not dispatch/4"
  )

  register_error("anemos.runtime/not_an_interaction", :validation,
    message: "Not something a host may raise as an interaction"
  )

  # `flow <name>`: the flow is looked up when the statement runs; a failed
  # step stops the rest. `field` is "flow/step" on the halt.
  register_error("anemos.runtime/unknown_flow", :validation,
    message: "No flow of that name is loaded"
  )

  register_error("anemos.runtime/flow_halted", :validation,
    message: "A step of the flow failed, so the steps after it did not run"
  )

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

  # --- Dispatch ---

  # A host verb answered `{:error, reason}` with a reason of its own. Its
  # tag is carried in the message; a host that wants more said answers a
  # structured error itself, which passes through untouched.
  register_error("anemos.runtime/verb_failed", :internal, message: "The verb reported a failure")

  register_error("anemos.runtime/capability_crash", :internal,
    message: "The capability's body raised"
  )

  register_error("anemos.runtime/demand_failed", :auth, message: "The demand was not met")

  register_error("anemos.runtime/already_registered", :validation,
    message: "The name is bound to a different module"
  )

  register_error("anemos.runtime/unknown_action", :validation,
    message: "Not an action this component performs"
  )

  register_error("anemos.runtime/not_in_a_runtime", :validation,
    message: "The verb was called outside a running runtime"
  )

  # --- Path confinement (`Anemos.Runtime.PathGuard`) ---

  register_error("anemos.path/outside_root", :auth, message: "The path leaves its root")
  register_error("anemos.path/not_a_path", :validation, message: "The value is not a path")
  register_error("anemos.path/unknown_root", :auth, message: "The path root is not configured")

  # --- Durations and dates ---

  register_error("anemos.duration/unknown_unit", :validation,
    message: "The duration names a unit that does not exist"
  )

  register_error("anemos.duration/invalid", :validation, message: "The value is not a duration")

  register_error("anemos.nld/unknown_expression", :validation,
    message: "The date expression is not one the runtime resolves"
  )

  # --- Trust (`Anemos.Runtime.TrustStore`, `LoadAuthority.Signed`) ---
  #
  # `field` is the signer's name where there is one.

  register_error("anemos.trust/no_trust_store", :auth, message: "The runtime has no trust store")

  register_error("anemos.trust/private_key_material", :validation,
    message: "A trust store holds public keys only"
  )

  register_error("anemos.trust/unknown_signer", :auth,
    message: "The signer is not in the keyring"
  )

  register_error("anemos.trust/missing_signature", :auth,
    message: "No signature was supplied for a declared signer"
  )

  register_error("anemos.trust/malformed_signature", :auth,
    message: "The signature is not a signature"
  )

  register_error("anemos.trust/unsupported_algorithm", :auth,
    message: "The signer's key is not of a supported algorithm"
  )

  register_error("anemos.trust/bad_signature", :auth,
    message: "The signature does not verify against the source"
  )

  register_error("anemos.trust/unsigned", :auth,
    message: "The policy is unsigned and this runtime requires a signature"
  )

  # --- Loading ---

  register_error("anemos.runtime/invalid_option", :validation,
    message: "An option given to the runtime is not one it accepts"
  )

  register_error("anemos.runtime/not_loaded", :validation,
    message: "No policy of that name is loaded"
  )

  register_error("anemos.runtime/name_taken", :validation,
    message: "A name the policy declares is held by another policy"
  )

  # A declaration that loaded and will never do anything: the members of the
  # `{:partial, failures}` list `Anemos.Runtime.load/3` answers. `field` is
  # the schedule's event name or the data block's name.
  register_error("anemos.scheduler/interval_below_minimum", :validation,
    message: "Interval is below the scheduler's floor"
  )

  register_error("anemos.scheduler/schedule_limit_exceeded", :validation,
    message: "The scheduler holds as many schedules as it allows"
  )

  register_error("anemos.scheduler/date_in_past", :validation,
    message: "The date has already passed"
  )

  register_error("anemos.scheduler/unresolvable_nld", :validation,
    message: "The date expression could not be resolved"
  )

  register_error("anemos.scheduler/nld_in_past", :validation,
    message: "The date expression resolves to a time already passed"
  )

  register_error("anemos.scheduler/unknown_duration_unit", :validation,
    message: "The duration names a unit that does not exist"
  )

  register_error("anemos.scheduler/invalid_duration", :validation,
    message: "The duration is not a duration"
  )

  register_error("anemos.scheduler/invalid_time_spec", :validation,
    message: "The time is not one that exists"
  )

  register_error("anemos.scheduler/unsupported_time_spec", :validation,
    message: "The time and recurrence cannot be combined"
  )

  register_error("anemos.data/no_subscribable_handler", :validation,
    message: "No handler is registered for the feed's protocol"
  )

  register_error("anemos.data/subscribe_failed", :validation, message: "The feed did not start")

  register_error("anemos.data/no_data_model", :validation,
    message: "No handler is registered for the block's format"
  )

  register_error("anemos.data/data_model_failed", :validation,
    message: "The format handler did not build the block"
  )

  # What policy text names and the runtime does not hold. A policy may name
  # something another policy has yet to load, so none of these can be
  # refused at compile time; each is refused at the moment it is reached.
  register_error("anemos.runtime/unknown_rule", :validation,
    message: "nextrule names a rule that is not loaded"
  )

  # `field` is the variable name without its sigil.
  register_error("anemos.runtime/unbound_label", :validation,
    message: "An emit label interpolates a variable that nothing supplied"
  )

  register_error("anemos.runtime/unknown_dataset", :validation,
    message: "memberof names a data block that is not registered"
  )

  register_error("anemos.runtime/unknown_data_model", :validation,
    message: "No handler is registered for this data format or query engine"
  )

  register_error("anemos.runtime/query_missing_binding", :validation,
    message: "A binding the query expects is not bound where it was called"
  )

  register_error("anemos.runtime/query_failed", :internal,
    message: "The query engine did not answer the query"
  )

  # `:auth`: loading policy is the trust boundary (A-12). This is the
  # configured `Anemos.Runtime.LoadAuthority` refusing a load, not a parse
  # or compile failure — those still answer `{:error, reason}` from the
  # parser and compiler as before.
  register_error("anemos.runtime/load_denied", :auth,
    message: "Policy load refused by the configured load authority"
  )
end

defmodule Anemos.AST do
  @moduledoc """
  AST node structs for the Anemos DSL.

  Each struct represents a node in the abstract syntax tree produced by `Anemos.Parser`.
  All nodes carry a `:line` field for error reporting.
  """

  defmodule Program do
    @moduledoc "Top-level program node wrapping all parsed declarations."
    @enforce_keys []
    @type t :: %__MODULE__{declarations: list()}
    defstruct [:declarations]
  end

  defmodule SignedBy do
    @moduledoc """
    A source-level `signed_by` declaration (A-60).

    A detached signature covers the whole source, so provenance is a property
    of the file rather than of any one declaration in it. This is the placement
    that says so, and the only one under which a source carrying no `rule` —
    conditions, capabilities, data blocks — can make a provenance claim at all.
    """
    @enforce_keys []
    @type t :: %__MODULE__{signer: String.t() | nil, line: non_neg_integer() | nil}
    defstruct [:signer, :line]
  end

  defmodule Rule do
    @moduledoc "A named rule declaration with a body, optional metadata, and source line."
    @enforce_keys []
    @type t :: %__MODULE__{
            name: String.t() | nil,
            body: list(),
            meta: map() | nil,
            line: non_neg_integer() | nil
          }
    defstruct [:name, :body, :meta, :line]
  end

  defmodule Condition do
    @moduledoc "A named condition declaration with a body and source line."
    @enforce_keys []
    @type t :: %__MODULE__{name: String.t() | nil, body: list(), line: non_neg_integer() | nil}
    defstruct [:name, :body, :line]
  end

  defmodule Capability do
    @moduledoc "A named capability declaration with context, body, and source line."
    @enforce_keys []
    @type t :: %__MODULE__{
            name: String.t() | nil,
            context: String.t() | nil,
            body: list(),
            line: non_neg_integer() | nil
          }
    defstruct [:name, :context, :body, :line]
  end

  defmodule Flow do
    @moduledoc "A named flow declaration with a body and source line."
    @enforce_keys []
    @type t :: %__MODULE__{name: String.t() | nil, body: list(), line: non_neg_integer() | nil}
    defstruct [:name, :body, :line]
  end

  defmodule When do
    @moduledoc "A `when` trigger block: fires on an event, with optional duration, guard, and body."
    @enforce_keys []
    @type t :: %__MODULE__{
            event: String.t() | nil,
            duration: term(),
            guard: term(),
            body: list(),
            line: non_neg_integer() | nil
          }
    defstruct [:event, :duration, :guard, :body, :line]
  end

  defmodule If do
    @moduledoc "A conditional `if` block with an optional guard, body, and else branch."
    @enforce_keys []
    @type t :: %__MODULE__{
            condition: term(),
            guard: term(),
            body: list(),
            else_body: list() | nil,
            line: non_neg_integer() | nil
          }
    defstruct [:condition, :guard, :body, :else_body, :line]
  end

  defmodule At do
    @moduledoc "A time-triggered `at` block with a time spec, optional guard, and body."
    @enforce_keys []
    @type t :: %__MODULE__{
            time_spec: term(),
            guard: term(),
            body: list(),
            line: non_neg_integer() | nil
          }
    defstruct [:time_spec, :guard, :body, :line]
  end

  defmodule On do
    @moduledoc "An `on` invocation block triggered by a named invocation."
    @enforce_keys []
    @type t :: %__MODULE__{invocation: term(), body: list(), line: non_neg_integer() | nil}
    defstruct [:invocation, :body, :line]
  end

  defmodule It do
    @moduledoc "An `it` modal reference block."
    @enforce_keys []
    @type t :: %__MODULE__{modal_ref: term(), body: list(), line: non_neg_integer() | nil}
    defstruct [:modal_ref, :body, :line]
  end

  defmodule Context do
    @moduledoc "A context scope block with a dotted path and body."
    @enforce_keys []
    @type t :: %__MODULE__{path: String.t() | nil, body: list(), line: non_neg_integer() | nil}
    defstruct [:path, :body, :line]
  end

  defmodule Let do
    @moduledoc "A `let` variable binding."
    @enforce_keys []
    @type t :: %__MODULE__{name: String.t() | nil, value: term(), line: non_neg_integer() | nil}
    defstruct [:name, :value, :line]
  end

  defmodule Set do
    @moduledoc "A `set` variable assignment."
    @enforce_keys []
    @type t :: %__MODULE__{name: String.t() | nil, value: term(), line: non_neg_integer() | nil}
    defstruct [:name, :value, :line]
  end

  defmodule Command do
    @moduledoc "A module command expression with a verb and arguments."
    @enforce_keys []
    @type t :: %__MODULE__{
            module: String.t() | nil,
            verb: String.t() | nil,
            args: list(),
            line: non_neg_integer() | nil
          }
    defstruct [:module, :verb, :args, :line]
  end

  defmodule Emit do
    @moduledoc "An `emit` expression that produces a typed value to an optional destination."
    @enforce_keys []
    @type t :: %__MODULE__{
            type: atom() | nil,
            value: term(),
            destination: term(),
            label: term(),
            line: non_neg_integer() | nil
          }
    defstruct [:type, :value, :destination, :label, :line]
  end

  defmodule Demand do
    @moduledoc "A `demand` expression referencing a capability with a PAM-style control flag."
    @enforce_keys []
    @type t :: %__MODULE__{
            capability: String.t() | nil,
            flag: atom() | nil,
            line: non_neg_integer() | nil
          }
    defstruct [:capability, :flag, :line]
  end

  defmodule Log do
    @moduledoc "A `log` expression."
    @enforce_keys []
    @type t :: %__MODULE__{expression: term(), line: non_neg_integer() | nil}
    defstruct [:expression, :line]
  end

  defmodule Introspect do
    @moduledoc """
    An introspection statement — `show`, `list`, `graph`, `trace`,
    `explain`, `exists`, `infer`, `assert` — or `exists` in expression
    position. The subject is a bare `{:name, "NAME"}`, a `{:catalogue,
    :rules | :conditions | :modules | :events | :policies | :schedules}`, or
    `{:expr, expression}`.
    """
    @enforce_keys []
    @type t :: %__MODULE__{verb: atom(), subject: term(), line: non_neg_integer() | nil}
    defstruct [:verb, :subject, :line]
  end

  defmodule BinaryOp do
    @moduledoc "A binary operator expression."
    @enforce_keys []
    @type t :: %__MODULE__{
            op: atom() | nil,
            left: term(),
            right: term(),
            line: non_neg_integer() | nil
          }
    defstruct [:op, :left, :right, :line]
  end

  defmodule UnaryOp do
    @moduledoc "A unary operator expression."
    @enforce_keys []
    @type t :: %__MODULE__{op: atom() | nil, operand: term(), line: non_neg_integer() | nil}
    defstruct [:op, :operand, :line]
  end

  defmodule Literal do
    @moduledoc "A literal value node (string, integer, float, boolean, atom)."
    @enforce_keys []
    @type t :: %__MODULE__{type: atom() | nil, value: term(), line: non_neg_integer() | nil}
    defstruct [:type, :value, :line]
  end

  defmodule VarRef do
    @moduledoc "A variable reference with an optional sigil prefix."
    @enforce_keys []
    @type t :: %__MODULE__{
            sigil: String.t() | nil,
            name: String.t() | nil,
            line: non_neg_integer() | nil
          }
    defstruct [:sigil, :name, :line]
  end

  defmodule Triple do
    @moduledoc "An RDF-style triple with subject, predicate, and object."
    @enforce_keys []
    @type t :: %__MODULE__{
            subject: term(),
            predicate: term(),
            object: term(),
            line: non_neg_integer() | nil
          }
    defstruct [:subject, :predicate, :object, :line]
  end

  defmodule ListLiteral do
    @moduledoc "A list literal expression."
    @enforce_keys []
    @type t :: %__MODULE__{elements: list(), line: non_neg_integer() | nil}
    defstruct [:elements, :line]
  end

  defmodule BlockArgs do
    @moduledoc "A block argument list of key-value pairs."
    @enforce_keys []
    @type t :: %__MODULE__{pairs: list(), line: non_neg_integer() | nil}
    defstruct [:pairs, :line]
  end

  defmodule While do
    @moduledoc "A `while` loop: repeats body while condition is truthy."
    @enforce_keys []
    @type t :: %__MODULE__{condition: term(), body: list(), line: non_neg_integer() | nil}
    defstruct [:condition, :body, :line]
  end

  defmodule For do
    @moduledoc "A `for` loop: iterates `var` over `iterable`, executing body each time. Covers `for`, `each`, `every`, `foreach`."
    @enforce_keys []
    @type t :: %__MODULE__{
            var: String.t() | nil,
            iterable: term(),
            body: list(),
            keyword: atom() | nil,
            line: non_neg_integer() | nil
          }
    defstruct [:var, :iterable, :body, :keyword, :line]
  end

  defmodule Return do
    @moduledoc "A `return` statement: exits the current handler, optionally with a value."
    @enforce_keys []
    @type t :: %__MODULE__{value: term(), line: non_neg_integer() | nil}
    defstruct [:value, :line]
  end

  defmodule Done do
    @moduledoc "A `done` statement: exits the current handler with no value."
    @enforce_keys []
    @type t :: %__MODULE__{line: non_neg_integer() | nil}
    defstruct [:line]
  end

  defmodule NextEvent do
    @moduledoc """
    A `nextevent` statement: transitions to another `when` block within the
    same rule, optionally carrying a `with { }` argument block (A-55).
    """
    @enforce_keys []
    @type t :: %__MODULE__{
            target: String.t() | nil,
            args: Anemos.AST.BlockArgs.t() | nil,
            line: non_neg_integer() | nil
          }
    defstruct [:target, :args, :line]
  end

  defmodule NextRule do
    @moduledoc """
    A `nextrule` statement: dispatches to a different rule's pipeline,
    optionally carrying a `with { }` argument block.
    """
    @enforce_keys []
    @type t :: %__MODULE__{
            target: String.t() | nil,
            args: Anemos.AST.BlockArgs.t() | nil,
            line: non_neg_integer() | nil
          }
    defstruct [:target, :args, :line]
  end

  defmodule DataDecl do
    @moduledoc "A named data declaration with content, optional source/transclude, scope, and source line."
    @enforce_keys []
    @type t :: %__MODULE__{
            name: String.t() | nil,
            source: String.t() | nil,
            content:
              {:simple_list, list()}
              | {:format_block, String.t(), String.t()}
              | {:dynamic, {:subscribe, String.t(), String.t()}},
            transclude: {:transclude, String.t(), String.t(), String.t()} | nil,
            scope: :local | :global,
            line: non_neg_integer() | nil
          }
    defstruct [:name, :source, :content, :transclude, :scope, :line]
  end

  defmodule BuiltinCall do
    @moduledoc "A built-in function call (filter, map, reduce, emit)."
    @enforce_keys []
    @type t :: %__MODULE__{
            name: :filter | :map | :reduce | :emit,
            args: list(),
            line: non_neg_integer() | nil
          }
    defstruct [:name, :args, :line]
  end

  defmodule QueryDecl do
    @moduledoc "A named query declaration with expect/engine/body/return, scope, and source line."
    @enforce_keys []
    @type t :: %__MODULE__{
            name: String.t() | nil,
            # Binaries, not atoms: `expect` names are arbitrary query bindings the
            # policy author invents, so there is no closed set to validate against
            # and interning them from untrusted source text is unbounded (A-08).
            expect: [String.t()],
            engine: String.t() | nil,
            body: String.t() | nil,
            return: String.t() | nil,
            scope: :local | :global,
            line: non_neg_integer() | nil
          }
    defstruct [:name, :expect, :engine, :body, :return, :scope, :line]
  end
end

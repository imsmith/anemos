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

  defmodule Rule do
    @moduledoc "A named rule declaration with a body, optional metadata, and source line."
    @enforce_keys []
    @type t :: %__MODULE__{name: String.t() | nil, body: list(), meta: map() | nil, line: non_neg_integer() | nil}
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
    @type t :: %__MODULE__{name: String.t() | nil, context: String.t() | nil, body: list(), line: non_neg_integer() | nil}
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
    @type t :: %__MODULE__{event: String.t() | nil, duration: term(), guard: term(), body: list(), line: non_neg_integer() | nil}
    defstruct [:event, :duration, :guard, :body, :line]
  end

  defmodule If do
    @moduledoc "A conditional `if` block with an optional guard, body, and else branch."
    @enforce_keys []
    @type t :: %__MODULE__{condition: term(), guard: term(), body: list(), else_body: list() | nil, line: non_neg_integer() | nil}
    defstruct [:condition, :guard, :body, :else_body, :line]
  end

  defmodule At do
    @moduledoc "A time-triggered `at` block with a time spec, optional guard, and body."
    @enforce_keys []
    @type t :: %__MODULE__{time_spec: term(), guard: term(), body: list(), line: non_neg_integer() | nil}
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
    @type t :: %__MODULE__{module: String.t() | nil, verb: String.t() | nil, args: list(), line: non_neg_integer() | nil}
    defstruct [:module, :verb, :args, :line]
  end

  defmodule Emit do
    @moduledoc "An `emit` expression that produces a typed value to an optional destination."
    @enforce_keys []
    @type t :: %__MODULE__{type: atom() | nil, value: term(), destination: term(), label: term(), line: non_neg_integer() | nil}
    defstruct [:type, :value, :destination, :label, :line]
  end

  defmodule Demand do
    @moduledoc "A `demand` expression referencing a capability with a PAM-style control flag."
    @enforce_keys []
    @type t :: %__MODULE__{capability: String.t() | nil, flag: atom() | nil, line: non_neg_integer() | nil}
    defstruct [:capability, :flag, :line]
  end

  defmodule Log do
    @moduledoc "A `log` expression."
    @enforce_keys []
    @type t :: %__MODULE__{expression: term(), line: non_neg_integer() | nil}
    defstruct [:expression, :line]
  end

  defmodule BinaryOp do
    @moduledoc "A binary operator expression."
    @enforce_keys []
    @type t :: %__MODULE__{op: atom() | nil, left: term(), right: term(), line: non_neg_integer() | nil}
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
    @type t :: %__MODULE__{sigil: String.t() | nil, name: String.t() | nil, line: non_neg_integer() | nil}
    defstruct [:sigil, :name, :line]
  end

  defmodule Triple do
    @moduledoc "An RDF-style triple with subject, predicate, and object."
    @enforce_keys []
    @type t :: %__MODULE__{subject: term(), predicate: term(), object: term(), line: non_neg_integer() | nil}
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
    @type t :: %__MODULE__{var: String.t() | nil, iterable: term(), body: list(), keyword: atom() | nil, line: non_neg_integer() | nil}
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
    @moduledoc "A `nextevent` statement: transitions to another `when` block within the same rule."
    @enforce_keys []
    @type t :: %__MODULE__{target: String.t() | nil, args: map() | nil, line: non_neg_integer() | nil}
    defstruct [:target, :args, :line]
  end

  defmodule NextRule do
    @moduledoc "A `nextrule` statement: dispatches to a different rule's pipeline."
    @enforce_keys []
    @type t :: %__MODULE__{target: String.t() | nil, args: map() | nil, line: non_neg_integer() | nil}
    defstruct [:target, :args, :line]
  end
end

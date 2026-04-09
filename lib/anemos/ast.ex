defmodule Anemos.AST do
  defmodule Program do
    defstruct [:declarations]
  end

  defmodule Rule do
    defstruct [:name, :body, :meta, :line]
  end

  defmodule Condition do
    defstruct [:name, :body, :line]
  end

  defmodule Capability do
    defstruct [:name, :context, :body, :line]
  end

  defmodule Flow do
    defstruct [:name, :body, :line]
  end

  defmodule When do
    defstruct [:event, :duration, :guard, :body, :line]
  end

  defmodule If do
    defstruct [:condition, :guard, :body, :else_body, :line]
  end

  defmodule At do
    defstruct [:time_spec, :guard, :body, :line]
  end

  defmodule On do
    defstruct [:invocation, :body, :line]
  end

  defmodule It do
    defstruct [:modal_ref, :body, :line]
  end

  defmodule Context do
    defstruct [:path, :body, :line]
  end

  defmodule Let do
    defstruct [:name, :value, :line]
  end

  defmodule Set do
    defstruct [:name, :value, :line]
  end

  defmodule Command do
    defstruct [:module, :verb, :args, :line]
  end

  defmodule Emit do
    defstruct [:type, :value, :destination, :label, :line]
  end

  defmodule Demand do
    defstruct [:capability, :flag, :line]
  end

  defmodule Log do
    defstruct [:expression, :line]
  end

  defmodule BinaryOp do
    defstruct [:op, :left, :right, :line]
  end

  defmodule UnaryOp do
    defstruct [:op, :operand, :line]
  end

  defmodule Literal do
    defstruct [:type, :value, :line]
  end

  defmodule VarRef do
    defstruct [:sigil, :name, :line]
  end

  defmodule Triple do
    defstruct [:subject, :predicate, :object, :line]
  end

  defmodule ListLiteral do
    defstruct [:elements, :line]
  end

  defmodule BlockArgs do
    defstruct [:pairs, :line]
  end
end

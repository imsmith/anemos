defmodule Anemos.DataModel do
  @moduledoc """
  Behaviour for pluggable data format and query engine handlers.

  Implementations register a keyword (e.g., "edn", "xml", "sql")
  that becomes valid inside data and query block bodies. The runtime
  delegates parsing, evaluation, and transclude to the registered handler.
  """

  @doc "Returns the keyword string identifying this data format (e.g., `\"edn\"`, `\"xml\"`)."
  @callback keyword() :: String.t()

  @doc "Parses a raw string body into an internal representation. Returns `{:ok, parsed}` or `{:error, :parse_failed}`."
  @callback parse(raw :: String.t()) :: {:ok, map() | list() | String.t()} | {:error, :parse_failed}

  @doc "Evaluates a parsed value against the dispatch context. Returns `{:ok, result}` or `{:error, :eval_failed}`."
  @callback eval(parsed :: map() | list() | String.t(), context :: map()) :: {:ok, map() | list() | String.t()} | {:error, :eval_failed}

  @doc "Transduces data into a new shape. Returns `{:ok, result}`, `{:error, :not_supported}`, or `{:error, :transduce_failed}`."
  @callback transduce(data :: map() | list() | String.t(), shape :: String.t(), transducer :: String.t()) :: {:ok, map() | list() | String.t()} | {:error, :not_supported} | {:error, :transduce_failed}
end

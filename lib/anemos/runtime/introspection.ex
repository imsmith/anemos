defmodule Anemos.Runtime.Introspection do
  @moduledoc """
  Answers the introspection statements — `show`, `list`, `graph`, `trace`,
  `explain`, `exists`, `infer` — from the dispatcher's state.

  The subject decides what is asked: a bare name is a module if one is
  bound to it, else an event if anything listens for it; a catalogue word
  names what the runtime holds; anything else is a value. The statement
  decides the question, after Comn: `show` is look, `explain` is recon,
  `list` is choices. See `docs/superpowers/specs/2026-10-03-introspection-design.md`.

  Every answer is the operation with `value` filled in, and for a name,
  `found`: `:module`, `:event` or `nil`.

  ## A policy sees itself, and the modules

  Rules, conditions, schedules, policies and listeners are answered
  within the asking rule's own policy: what it declared, and who among
  its own rules listens. Another policy's names, contexts and condition
  states are that policy's; the runtime-wide view belongs to the host
  (`Anemos.Runtime.describe/1`). Modules are the affordances every policy
  may ask about. A rule loaded with no policy name sees the other
  anonymous loads, which share its standing.
  """

  alias Anemos.Runtime.{ConditionServer, Module, ModuleRegistry, PolicyStore, TripleStore}

  @statements ~w(show list graph trace explain exists infer)a

  @doc "The statement types this answers."
  @spec statements() :: [atom()]
  def statements, do: @statements

  @doc "The operation, answered for the rule named in `context[:_rule_source]`."
  @spec answer(map(), map(), map()) :: map()
  def answer(op, context, state) do
    rule_name =
      case Map.get(context, :_rule_source) do
        {rule, _context_path} -> rule
        _ -> nil
      end

    answer(op, own(rule_name, state))
  end

  # The asking rule's policy: the entry declaring it, else the anonymous
  # entries if it was loaded without a name.
  defp own(rule_name, state) do
    entries = PolicyStore.entries(state.policy_store)

    mine =
      case Enum.find(Enum.reverse(entries), fn %{compiled: c} ->
             rule_name in Enum.map(c.rules, & &1.name)
           end) do
        %{id: id} when is_binary(id) -> Enum.filter(entries, &(&1.id == id))
        _ -> Enum.filter(entries, &is_nil(&1.id))
      end

    rule_names = MapSet.new(for %{compiled: c} <- mine, r <- c.rules, do: r.name)

    index =
      state.index
      |> Map.new(fn {e, rs} -> {e, Enum.filter(rs, &MapSet.member?(rule_names, &1.name))} end)
      |> Map.reject(fn {_e, rs} -> rs == [] end)

    %{
      entries: mine,
      rules: Enum.filter(state.rules, &MapSet.member?(rule_names, &1.name)),
      index: index,
      registry: state.registry,
      condition_servers: state.condition_servers,
      triple_store: state.triple_store
    }
  end

  defp answer(%{subject: {:name, name}} = op, state) do
    case ModuleRegistry.lookup(state.registry, name) do
      {:ok, module} ->
        op |> Map.put(:found, :module) |> Map.put(:value, module_answer(op.type, name, module))

      :error ->
        rules = state.index |> Map.get(name, []) |> Enum.map(& &1.name) |> Enum.uniq()
        conditions = listening_conditions(name, state)

        if rules == [] and conditions == [] do
          op |> Map.put(:found, nil) |> Map.put(:value, nothing_answer(op.type, name))
        else
          op
          |> Map.put(:found, :event)
          |> Map.put(:value, event_answer(op.type, name, rules, conditions))
        end
    end
  end

  defp answer(%{subject: {:catalogue, catalogue}} = op, state) do
    Map.put(op, :value, catalogue_answer(op.type, catalogue, state))
  end

  defp answer(%{subject: {:value, value}} = op, state) do
    Map.put(op, :value, value_answer(op.type, value, state))
  end

  # --- a module: Comn's look, recon, choices ---

  defp module_answer(type, name, module) do
    card = Module.card(module, name)

    case type do
      :show -> card.look
      :trace -> card.look
      :explain -> card.recon
      :list -> card.choices
      :exists -> true
      :infer -> %{kind: :module, module: module}
      :graph -> []
    end
  end

  # --- an event: who listens ---

  defp event_answer(type, name, rules, conditions) do
    case type do
      :show ->
        "event #{name}: #{count(rules, "rule")} and #{count(conditions, "condition")} listen"

      :trace ->
        "event #{name}: #{Enum.join(rules ++ conditions, ", ")}"

      :explain ->
        %{event: name, rules: rules, conditions: conditions}

      :list ->
        rules ++ conditions

      :exists ->
        true

      :infer ->
        %{kind: :event, listeners: length(rules) + length(conditions)}

      :graph ->
        []
    end
  end

  defp nothing_answer(type, name) do
    case type do
      :exists -> false
      :list -> []
      :graph -> []
      :explain -> %{name: name, found: nil}
      :infer -> %{kind: :nothing}
      _show_or_trace -> "#{name}: no module is bound to that name, and nothing listens for it"
    end
  end

  defp count([_], noun), do: "1 #{noun}"
  defp count(list, noun), do: "#{length(list)} #{noun}s"

  defp listening_conditions(event_name, state) do
    for %{compiled: c} <- state.entries,
        condition <- c.conditions,
        event_name in condition.subscriptions,
        uniq: true,
        do: condition.name
  end

  # --- a catalogue: what the runtime holds ---

  defp catalogue_answer(type, catalogue, state) do
    entries = catalogue_entries(catalogue, state)
    names = Enum.map(entries, & &1.name)

    case type do
      :list ->
        names

      :show ->
        "#{count(names, singular(catalogue))}: #{Enum.join(names, ", ")}"

      :trace ->
        names

      :explain ->
        entries

      :exists ->
        names != []

      :infer ->
        %{kind: :catalogue, count: length(names)}

      :graph ->
        []
    end
  end

  defp singular(:policies), do: "policy"
  defp singular(catalogue), do: catalogue |> Atom.to_string() |> String.trim_trailing("s")

  defp catalogue_entries(:rules, state) do
    state.rules
    |> Enum.group_by(& &1.name)
    |> Enum.map(fn {name, parts} ->
      %{
        name: name,
        events: parts |> Enum.flat_map(& &1.subscriptions) |> Enum.uniq(),
        context: get_in(hd(parts), [Access.key(:meta), :context_path])
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp catalogue_entries(:conditions, state) do
    mine = for %{compiled: c} <- state.entries, condition <- c.conditions, do: condition.name

    for {name, %{pid: pid}} <- Enum.sort(state.condition_servers), name in mine do
      %{name: name, value: ConditionServer.get_state(pid)}
    end
  end

  defp catalogue_entries(:modules, state) do
    for name <- ModuleRegistry.names(state.registry) do
      {:ok, module} = ModuleRegistry.lookup(state.registry, name)
      %{name: name, look: Module.card(module, name).look}
    end
  end

  defp catalogue_entries(:events, state) do
    for {event, rules} <- Enum.sort(state.index) do
      %{name: event, rules: rules |> Enum.map(& &1.name) |> Enum.uniq()}
    end
  end

  defp catalogue_entries(:policies, state) do
    for %{id: id, compiled: c} <- state.entries do
      %{name: id || "(anonymous)", rules: c.rules |> Enum.map(& &1.name) |> Enum.uniq()}
    end
  end

  defp catalogue_entries(:schedules, state) do
    for %{compiled: c} <- state.entries,
        schedule <- c.schedules,
        uniq: true do
      %{name: schedule.event_name, time_spec: schedule.time_spec, recurrence: schedule.recurrence}
    end
  end

  # --- a value ---

  defp value_answer(type, value, state) do
    case type do
      :show -> value
      :trace -> value
      :exists -> value != nil
      :infer -> kind(value)
      :explain -> kind(value)
      :list -> elements(value)
      :graph -> triples_about(value, state)
    end
  end

  defp kind(nil), do: %{kind: :nothing}
  defp kind(%Anemos.Secret{}), do: %{kind: :secret}
  defp kind(value) when is_binary(value), do: %{kind: :string, length: String.length(value)}
  defp kind(value) when is_boolean(value), do: %{kind: :boolean}
  defp kind(value) when is_number(value), do: %{kind: :number}
  defp kind(value) when is_list(value), do: %{kind: :list, length: length(value)}

  defp kind(%_{} = struct), do: %{kind: :struct, struct: inspect(struct.__struct__)}

  defp kind(value) when is_map(value),
    do: %{kind: :map, keys: value |> Map.keys() |> Enum.map(&key_text/1)}

  defp kind(_other), do: %{kind: :other}

  defp key_text(key) when is_binary(key), do: key
  defp key_text(key) when is_atom(key), do: Atom.to_string(key)
  defp key_text(key), do: inspect(key)

  defp elements(nil), do: []
  defp elements(list) when is_list(list), do: list
  defp elements(%Anemos.Secret{}), do: []
  defp elements(%{} = map), do: Map.keys(map)
  defp elements(other), do: [other]

  # Every triple the value is the subject or the object of.
  defp triples_about(_value, %{triple_store: nil}), do: []

  defp triples_about(value, %{triple_store: store}) do
    (TripleStore.query(store, value, :_, :_) ++ TripleStore.query(store, :_, :_, value))
    |> Enum.uniq()
    |> Enum.map(&Tuple.to_list/1)
  end
end

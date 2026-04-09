defimpl Anemos.Event, for: Map do
  @moduledoc false

  def name(map), do: Map.fetch!(map, :name)
  def context(map), do: Map.get(map, :context)
  def payload(map), do: Map.get(map, :payload, %{})
end

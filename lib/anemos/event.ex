defprotocol Anemos.Event do
  @moduledoc """
  Protocol for types that can be dispatched as Anemos events.

  Implement this protocol for your application's event types to make them
  dispatchable into an Anemos runtime without translation.

  ## Example

      defimpl Anemos.Event, for: MyApp.MQTTMessage do
        def name(msg), do: msg.topic |> String.upcase() |> String.replace("/", "_")
        def context(msg), do: msg.topic
        def payload(msg), do: msg.payload
      end

      # Then dispatch directly:
      Anemos.Runtime.dispatch(:anemos, mqtt_message)

  ## Required callbacks

    * `name/1` — the event name for rule matching (e.g., `"SENSOR_MOTION_DETECTED"`)
    * `context/1` — the context path for listener filtering (e.g., `"garage.motion"`)
    * `payload/1` — map of key-value data for `?` variable resolution
  """

  @doc "Event name for rule matching."
  @spec name(t) :: String.t()
  def name(event)

  @doc "Context path for listener-side filtering. Return `nil` for unscoped events."
  @spec context(t) :: String.t() | nil
  def context(event)

  @doc "Payload map — values are available via `?` variable resolution in policies."
  @spec payload(t) :: map()
  def payload(event)
end

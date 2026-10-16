defmodule Supabase.Realtime.Message do
  @moduledoc """
  Message encoding and decoding for Supabase Realtime.

  Builders for the Realtime wire messages plus vsn 1.0.0 JSON helpers
  (`encode/1` and `decode/1`); the Connection itself serializes through the
  negotiated serializer (`Supabase.Realtime.Serializer`).
  """

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Serializer

  @doc """
  Encodes a message for sending to the Supabase Realtime server, as a vsn
  1.0.0 JSON text frame payload.

  ## Parameters

  * `message` - The message to encode

  ## Returns

  * `{:ok, binary}` - JSON-encoded message
  * `{:error, term}` - Error information

  ## Examples

      iex> Supabase.Realtime.Message.encode(%{topic: "realtime:public", event: "INSERT", payload: %{}, ref: "1"})
      {:ok, "{\\"topic\\":\\"realtime:public\\",\\"event\\":\\"INSERT\\",\\"payload\\":{},\\"ref\\":\\"1\\"}"}
  """
  @spec encode(Realtime.realtime_message() | map()) :: {:ok, binary} | {:error, term}
  def encode(message) do
    with {:ok, {:text, json}} <- Serializer.V1.encode(message, []), do: {:ok, json}
  end

  @doc """
  Decodes a message received from the Supabase Realtime server, as a vsn
  1.0.0 JSON text frame payload.

  ## Parameters

  * `data` - The raw message data

  ## Returns

  * `{:ok, map}` - Decoded message
  * `{:error, term}` - Error information

  ## Examples

      iex> Supabase.Realtime.Message.decode("{\\"topic\\":\\"realtime:public\\",\\"event\\":\\"INSERT\\",\\"payload\\":{},\\"ref\\":\\"1\\"}")
      {:ok, %{"topic" => "realtime:public", "event" => "INSERT", "payload" => %{}, "ref" => "1"}}
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(data) when is_binary(data), do: Serializer.V1.decode({:text, data}, [])

  @doc """
  Constructs a subscription message for a channel.

  The join payload carries a flat `postgres_changes` list built from the
  channel bindings (never the binding struct keys), a `presence` config with
  an `enabled` flag, and the resolved access token when non-nil. `ref` and
  `join_ref` are added by the Connection (both set to the same fresh value).

  ## Parameters

  * `channel` - The channel struct
  * `token` - The resolved access token, or nil to omit it

  ## Returns

  * `map` - Subscription message payload
  """
  @spec subscription_message(Channel.t(), String.t() | nil) :: map()
  def subscription_message(%Channel{} = channel, token) do
    postgres_changes =
      channel.bindings
      |> Map.get("postgres_changes", [])
      |> Enum.map(&postgres_binding_filter/1)

    presence =
      channel.params.config
      |> Map.get(:presence, %{key: ""})
      |> Map.put(:enabled, presence_enabled?(channel))

    config =
      channel.params.config
      |> Map.put(:postgres_changes, postgres_changes)
      |> Map.put(:presence, presence)

    payload = %{config: config}
    payload = if token, do: Map.put(payload, :access_token, token), else: payload

    %{topic: channel.topic, event: "phx_join", payload: payload}
  end

  defp presence_enabled?(%Channel{} = channel) do
    user_enabled =
      channel.params.config
      |> Map.get(:presence, %{})
      |> Map.get(:enabled, false)

    has_presence_bindings? =
      channel.bindings
      |> Map.get("presence", [])
      |> length() > 0

    user_enabled or has_presence_bindings?
  end

  # Flat server shape per binding, dropping nil keys. Never sends the binding
  # struct keys (type/filter/callback/id). `select` is present only when the
  # binding filter carries it (validated by Channel.normalize_filter/2).
  defp postgres_binding_filter(binding) do
    filter = binding.filter

    %{
      event: normalize_postgres_event(binding_filter_value(filter, :event)),
      schema: binding_filter_value(filter, :schema),
      table: binding_filter_value(filter, :table),
      filter: binding_filter_value(filter, :filter),
      select: binding_filter_value(filter, :select)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp binding_filter_value(filter, key) when is_map(filter) do
    Map.get(filter, key) || Map.get(filter, to_string(key))
  end

  # :all | "*" -> "*"; :insert | "insert" | "INSERT" -> "INSERT"; same for
  # UPDATE/DELETE; anything else passes through String.upcase(to_string/1)
  # (the server does no runtime validation either).
  defp normalize_postgres_event(:all), do: "*"
  defp normalize_postgres_event("*"), do: "*"
  defp normalize_postgres_event(value), do: String.upcase(to_string(value))

  @doc """
  Constructs an unsubscribe message for a channel.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `map` - Unsubscribe message payload
  """
  @spec unsubscribe_message(Channel.t()) :: map()
  def unsubscribe_message(%Channel{} = channel) do
    %{
      topic: channel.topic,
      event: "phx_leave",
      payload: %{}
    }
  end

  @doc """
  Constructs a broadcast message.

  ## Parameters

  * `channel` - The channel struct
  * `event` - The event name
  * `payload` - The message payload

  ## Returns

  * `map` - Broadcast message payload
  """
  @spec broadcast_message(Channel.t(), String.t(), map()) :: map()
  def broadcast_message(%Channel{} = channel, event, payload) do
    %{
      topic: channel.topic,
      event: "broadcast",
      payload: %{
        type: "broadcast",
        event: event,
        payload: payload
      }
    }
  end

  @doc """
  Constructs a broadcast message with acknowledgment support.

  ## Parameters

  * `channel` - The channel struct
  * `event` - The event name
  * `payload` - The message payload
  * `ack_ref` - The acknowledgment reference

  ## Returns

  * `map` - Broadcast message payload with acknowledgment reference
  """
  @spec broadcast_message_with_ack(Channel.t(), String.t(), map(), String.t()) :: map()
  def broadcast_message_with_ack(%Channel{} = channel, event, payload, ack_ref) do
    %{
      topic: channel.topic,
      event: "broadcast",
      payload: %{
        type: "broadcast",
        event: event,
        payload: payload
      },
      # under :ref so it survives encoding as the wire ref; the server echoes
      # it back as the phx_reply ref
      ref: ack_ref
    }
  end

  @doc """
  Constructs an access token update message.

  ## Parameters

  * `channel` - The channel struct
  * `token` - The new access token

  ## Returns

  * `map` - Access token message payload
  """
  @spec access_token_message(Channel.t(), String.t()) :: map()
  def access_token_message(%Channel{} = channel, token) do
    %{
      topic: channel.topic,
      event: "access_token",
      payload: %{
        access_token: token
      }
    }
  end

  @doc """
  Constructs a heartbeat message.

  ## Returns

  * `map` - Heartbeat message payload
  """
  @spec heartbeat_message() :: map()
  def heartbeat_message do
    %{topic: "phoenix", event: "heartbeat", payload: %{}}
  end

  @doc """
  Constructs a presence tracking message.

  ## Parameters

  * `channel` - The channel struct
  * `presence_state` - The presence state to track

  ## Returns

  * `map` - Presence track message payload
  """
  @spec presence_track_message(Channel.t(), map()) :: map()
  def presence_track_message(%Channel{} = channel, presence_state) do
    %{
      topic: channel.topic,
      event: "presence",
      payload: %{
        type: "presence",
        event: "track",
        payload: presence_state
      }
    }
  end

  @doc """
  Constructs a presence untrack message.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `map` - Presence untrack message payload
  """
  @spec presence_untrack_message(Channel.t()) :: map()
  def presence_untrack_message(%Channel{} = channel) do
    %{
      topic: channel.topic,
      event: "presence",
      payload: %{
        type: "presence",
        event: "untrack"
      }
    }
  end
end

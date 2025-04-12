defmodule Supabase.Realtime.Message do
  @moduledoc """
  Message encoding and decoding for Supabase Realtime.

  This module handles serialization and deserialization of the WebSocket messages
  exchanged with the Supabase Realtime service.
  """

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel

  @doc """
  Encodes a message for sending to the Supabase Realtime server.

  ## Parameters

  * `message` - The message to encode

  ## Returns

  * `binary` - JSON-encoded message

  ## Examples

      iex> Message.encode(%{topic: "realtime:public", event: "INSERT", payload: %{}, ref: "1"})
      "{\"topic\":\"realtime:public\",\"event\":\"INSERT\",\"payload\":{},\"ref\":\"1\"}"
  """
  @spec encode(Realtime.realtime_message() | map()) :: {:ok, binary} | {:error, term}
  def encode(message), do: Jason.encode(message)

  @doc """
  Decodes a message received from the Supabase Realtime server.

  ## Parameters

  * `data` - The raw message data

  ## Returns

  * `{:ok, map}` - Decoded message
  * `{:error, term}` - Error information

  ## Examples

      iex> Message.decode("{\"topic\":\"realtime:public\",\"event\":\"INSERT\",\"payload\":{},\"ref\":\"1\"}")
      {:ok, %{"topic" => "realtime:public", "event" => "INSERT", "payload" => %{}, "ref" => "1"}}
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(data) when is_binary(data), do: Jason.decode(data)

  @doc """
  Constructs a subscription message for a channel.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `map` - Subscription message payload
  """
  @spec subscription_message(Channel.t()) :: map()
  def subscription_message(%Channel{} = channel) do
    postgres_changes = Map.get(channel.bindings, "postgres_changes", [])

    config = Map.put(channel.params.config, :postgres_changes, postgres_changes)

    %{
      topic: channel.topic,
      event: "phx_join",
      payload: %{
        config: config
      }
    }
  end

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

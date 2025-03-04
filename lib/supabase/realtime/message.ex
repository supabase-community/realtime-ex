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
  * `bindings` - Channel bindings for the subscription

  ## Returns

  * `map` - Subscription message payload
  """
  @spec subscription_message(Channel.t(), map()) :: map()
  def subscription_message(%Channel{} = channel, bindings \\ %{}) do
    postgres_changes = Map.get(bindings, "postgres_changes", [])

    config = Map.put(channel.params.config, :postgres_changes, postgres_changes)

    %{
      topic: channel.topic,
      event: "phx_join",
      payload: %{
        config: config
      },
      ref: channel.ref
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
      payload: %{},
      ref: channel.ref
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
      },
      ref: channel.ref
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
      },
      ref: channel.ref
    }
  end
end

defmodule Supabase.Realtime.HTTP do
  @moduledoc """
  HTTP fallback for Supabase Realtime broadcasts.

  Sends broadcast messages through the Supabase REST API when the WebSocket
  connection is not available.

  ## When Does the Fallback Trigger?

  All three conditions must be true:

  1. The WebSocket connection status is not `:open`.
  2. The `:http_fallback` option is set to `true` on the connection.
  3. The message being sent is a broadcast message.

  Other message types (presence, postgres_changes) are never sent over HTTP.
  They go into the send buffer and wait for the WebSocket to reconnect.

  ## Example

      # Usually called by the Connection module, which passes the channel topic
      # (the `realtime:` prefix is stripped here) and the private flag:
      Supabase.Realtime.HTTP.broadcast(client, token, "realtime:room:lobby", "new_msg", %{body: "hi"},
        private: true
      )
  """

  alias Supabase.Fetcher
  alias Supabase.Fetcher.Request

  require Logger

  @doc """
  Sends a broadcast message via HTTP POST using the Supabase Fetcher.

  The `realtime:` topic prefix is stripped from `topic`, matching the JS
  fallback's `topic: this.subTopic` wire shape.

  ## Parameters

  * `client` - The `Supabase.Client` struct
  * `token` - The access token for authorization
  * `topic` - The channel topic
  * `event` - The broadcast event name
  * `payload` - The message payload

  ## Options

  * `:private` - whether the channel is private (default `false`). Sent as
    `private` on each message; the REST API authorizes private-channel
    broadcasts with it.
  """
  @spec broadcast(Supabase.Client.t(), String.t(), String.t(), String.t(), map(), keyword()) ::
          :ok | {:error, term()}
  def broadcast(%Supabase.Client{} = client, token, topic, event, payload, opts \\ []) do
    private = Keyword.get(opts, :private, false)

    body = %{
      messages: [
        %{topic: strip_topic_prefix(topic), event: event, payload: payload, private: private}
      ]
    }

    request =
      client
      |> Request.new()
      |> Request.with_realtime_url("/api/broadcast")
      |> Request.with_method(:post)
      |> Request.with_headers(%{"authorization" => "Bearer #{token}"})
      |> Request.with_body(body)

    case Fetcher.request(request) do
      {:ok, _response} ->
        :ok

      {:error, reason} ->
        Logger.error("[#{__MODULE__}]: HTTP broadcast failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Every Elixir code path constructs topics with the exact `realtime:`
  # prefix (Channel.new/3, Registry.normalize_topic), so an exact-prefix
  # strip is complete (JS strips case-insensitively; unneeded here).
  defp strip_topic_prefix("realtime:" <> sub_topic), do: sub_topic
  defp strip_topic_prefix(topic), do: topic
end

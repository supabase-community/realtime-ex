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

      # Usually called by the Connection module, but can be used directly:
      Supabase.Realtime.HTTP.broadcast(client, token, "realtime:room:lobby", "new_msg", %{body: "hi"})
  """

  alias Supabase.Fetcher
  alias Supabase.Fetcher.Request

  require Logger

  @doc """
  Sends a broadcast message via HTTP POST using the Supabase Fetcher.

  ## Parameters

  * `client` - The `Supabase.Client` struct
  * `token` - The access token for authorization
  * `topic` - The channel topic
  * `event` - The broadcast event name
  * `payload` - The message payload
  """
  @spec broadcast(Supabase.Client.t(), String.t(), String.t(), String.t(), map()) ::
          :ok | {:error, term()}
  def broadcast(%Supabase.Client{} = client, token, topic, event, payload) do
    body = %{
      messages: [
        %{topic: topic, event: event, payload: payload}
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
end

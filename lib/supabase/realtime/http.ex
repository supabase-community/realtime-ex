defmodule Supabase.Realtime.HTTP do
  @moduledoc """
  HTTP fallback for Supabase Realtime broadcasts.

  When the WebSocket connection is unavailable, this module provides
  an HTTP POST fallback to deliver broadcast messages via the REST API.
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
  def broadcast(client, token, topic, event, payload) do
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

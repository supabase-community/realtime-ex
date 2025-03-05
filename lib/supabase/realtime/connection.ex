defmodule Supabase.Realtime.Connection do
  @moduledoc """
  WebSocket connection manager for Supabase Realtime.

  This module is responsible for:
  * Establishing and maintaining the WebSocket connection
  * Sending and receiving messages
  * Handling reconnection with exponential backoff
  * Managing heartbeats to detect connection health
  """

  use GenServer

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Message

  require Logger

  @typedoc """
  Connection state.
  """
  @type state :: %{
          url: String.t(),
          params: map(),
          registry: atom(),
          socket: pid() | nil,
          status: Realtime.connection_state(),
          pending: map(),
          stream_ref: reference() | nil,
          reconnect_timer: reference() | nil,
          heartbeat_timer: reference() | nil,
          heartbeat_interval: pos_integer(),
          pending_heartbeat_ref: Realtime.ref() | nil,
          reconnect_attempts: non_neg_integer(),
          reconnect_after_ms: (non_neg_integer() -> pos_integer())
        }

  # Client API

  @doc """
  Starts the connection manager.

  ## Options

  * `:name` - Optional registration name
  * `:registry` - Registry process name
  * `:client` - The `Supabase.Client` self-managed client name
  * `:heartbeat_interval` - Interval in milliseconds between heartbeats
  * `:reconnect_after_ms` - Function that returns reconnection delay based on attempts
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    _ = Keyword.fetch!(opts, :registry)
    _ = Keyword.fetch!(opts, :client)

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends a message on a channel.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  * `payload` - The message payload
  """
  @spec send_message(GenServer.server(), Channel.t(), map()) :: :ok | {:error, term()}
  def send_message(server, %Channel{} = channel, payload) do
    GenServer.call(server, {:send_message, channel, payload})
  end

  @doc """
  Gets the current connection state.

  ## Parameters

  * `server` - The server PID or name
  """
  @spec state(GenServer.server()) :: Realtime.connection_state()
  def state(server), do: GenServer.call(server, :state)

  # Server callbacks

  @impl true
  def init(opts) do
    client = opts[:client]
    registry = opts[:registry]
    heartbeat_interval = opts[:heartbeat_interval] || :timer.seconds(30)
    reconnect_function = opts[:reconnect_after_ms] || (&default_reconnect_after_ms/1)

    state = %{
      client: client,
      registry: registry,
      socket: nil,
      status: :closed,
      stream_ref: nil,
      pending: %{},
      reconnect_timer: nil,
      heartbeat_timer: nil,
      heartbeat_interval: heartbeat_interval,
      pending_heartbeat_ref: nil,
      reconnect_attempts: 0,
      reconnect_after_ms: reconnect_function
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, socket, updated_state} ->
        heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

        {:noreply, %{updated_state | socket: socket, heartbeat_timer: heartbeat_timer}}

      {:error, reason, updated_state} ->
        Logger.error("[#{__MODULE__}]: Failed to connect: #{inspect(reason)}")
        reconnect_timer = schedule_reconnect(updated_state)

        {:noreply, %{updated_state | reconnect_timer: reconnect_timer}}
    end
  end

  def handle_continue(:upgrade, %{socket: socket} = state) do
    {:ok, client} = state.client.get_client()
    uri = build_url(client)
    path = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

    headers = [
      {~c"user-agent", ~c"SupabasePotion/#{version()}"},
      {~c"x-client-info", ~c"supabase-realtime-elixir/#{version()}"},
      # {"apikey", client.apikey},
      {~c"authorization", ~c"Bearer #{client.access_token || client.apikey}"}
    ]

    stream_ref = :gun.ws_upgrade(socket, path, headers)

    {:noreply, %{state | stream_ref: stream_ref}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.status, state}

  def handle_call({:send_message, channel, _}, _from, %{status: status, socket: nil} = state)
      when status != :open do
    Logger.warning(
      "[#{inspect(__MODULE__)}]: Not connected, ignoring message for channel: #{inspect(channel)}"
    )

    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_message, channel, payload}, _from, state) do
    {:ok, message_ref} = send_message_to_topic(channel.topic, payload, state)

    {:reply, :ok, %{state | pending: Map.put(state.pending, message_ref, channel)}}
  end

  @impl true
  def handle_info({:gun_up, socket, _protocol}, %{socket: socket} = state) do
    Logger.debug("[#{__MODULE__}]: Connection established")
    updated_state = %{state | reconnect_attempts: 0}
    heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

    {:noreply, %{updated_state | heartbeat_timer: heartbeat_timer}, {:continue, :upgrade}}
  end

  def handle_info({:gun_response, socket, _, _, status, headers}, %{socket: socket} = state) do
    Logger.debug("[#{__MODULE__}]: Failed to upgrade to websocket: #{inspect(status)}")
    # maybe try to upgrade again? stop? i dunno
    {:stop, {:error, {:failed_to_upgrade, status, headers}}, %{state | status: :closed}}
  end

  def handle_info(
        {:gun_error, socket, stream, reason},
        %{socket: socket, stream_ref: stream} = state
      ) do
    Logger.error("[#{__MODULE__}]: Connection error: #{inspect(reason)}")
    {:stop, {:error, reason}, %{state | status: :closed}}
  end

  def handle_info(
        {:gun_upgrade, socket, stream, ["websocket"], _headers},
        %{socket: socket, stream_ref: stream} = state
      ) do
    Logger.debug("[#{__MODULE__}]: Connection upgraded to websocket with success")
    {:noreply, %{state | status: :open}}
  end

  def handle_info(
        {:gun_down, socket, _protocol, reason, _killed_streams},
        %{socket: socket} = state
      ) do
    Logger.debug("[#{__MODULE__}]: Connection down: #{inspect(reason)}")
    updated_state = %{state | status: :closed}

    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    reconnect_timer = schedule_reconnect(updated_state)

    {:noreply, %{updated_state | heartbeat_timer: nil, reconnect_timer: reconnect_timer}}
  end

  def handle_info(
        {:gun_ws, socket, stream, {:text, data}},
        %{socket: socket, stream_ref: stream} = state
      ) do
    case Message.decode(data) do
      {:ok, message} ->
        handle_ws_message(message, state)

      {:error, reason} ->
        Logger.error("[#{__MODULE__}]: Failed to decode message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(:heartbeat, %{socket: nil, status: status} = state) when status != :open do
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    heartbeat_ref = generate_join_ref()

    message = %{
      event: "heartbeat",
      payload: %{},
      ref: heartbeat_ref
    }

    send_message_to_topic("phoenix", message, state)
    heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

    {:noreply, %{state | heartbeat_timer: heartbeat_timer, pending_heartbeat_ref: heartbeat_ref}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    case connect(%{state | reconnect_attempts: state.reconnect_attempts + 1}) do
      {:ok, socket, updated_state} ->
        heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

        {:noreply,
         %{updated_state | socket: socket, heartbeat_timer: heartbeat_timer, reconnect_timer: nil}}

      {:error, _reason, updated_state} ->
        reconnect_timer = schedule_reconnect(updated_state)

        {:noreply, %{updated_state | reconnect_timer: reconnect_timer}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.status == :open and !!state.socket do
      :gun.close(state.socket)
    end

    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)
    if state.reconnect_timer, do: Process.cancel_timer(state.reconnect_timer)

    :ok
  end

  # Private helper functions

  defp connect(state) do
    {:ok, client} = state.client.get_client()
    uri = build_url(client)

    host = String.to_charlist(uri.host)
    port = uri.port || if uri.scheme == "wss", do: 443, else: 80

    gun_opts = %{
      protocols: [:http],
      http_opts: %{version: :"HTTP/1.1"},
      transport: if(uri.scheme == "wss", do: :tls, else: :tcp),
      tls_opts: [
        verify: :verify_none
      ]
    }

    case :gun.open(host, port, gun_opts) do
      {:ok, socket} ->
        # {:ok, _protocol} <- :gun.await_up(conn_pid, :timer.seconds(5)) do
        Process.monitor(socket)

        {:ok, socket, %{state | status: :connecting}}

      {:error, reason} ->
        Logger.error("[#{__MODULE__}]: Failed to connect: #{inspect(reason)}")
        {:error, reason, %{state | status: :closed}}
    end
  end

  defp build_url(%Supabase.Client{} = client) do
    query = URI.encode_query(%{apikey: client.api_key, vsn: "1.0.0"})

    URI.new!(client.realtime_url)
    |> URI.append_path("/websocket")
    |> URI.append_query(query)
    |> then(&update_uri_scheme/1)
  end

  defp update_uri_scheme(%URI{scheme: "http"} = uri), do: %{uri | scheme: "ws"}
  defp update_uri_scheme(%URI{scheme: "https"} = uri), do: %{uri | scheme: "wss"}
  defp update_uri_scheme(uri), do: uri

  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp schedule_reconnect(state) do
    reconnect_time = state.reconnect_after_ms.(state.reconnect_attempts)
    Process.send_after(self(), :reconnect, reconnect_time)
  end

  @max_backoff :timer.seconds(10)
  @base_backoff :timer.seconds(1)

  defp default_reconnect_after_ms(tries) do
    min(@max_backoff, (@base_backoff * 2) ** tries)
  end

  defp handle_ws_message(
         %{"topic" => "phoenix", "event" => "phx_reply", "ref" => ref},
         %{pending_heartbeat_ref: ref} = state
       ) do
    Logger.debug("[#{__MODULE__}]: Received heartbeat reply")
    {:noreply, %{state | pending_heartbeat_ref: nil}}
  end

  defp handle_ws_message(message, state) do
    Logger.debug("[#{__MODULE__}]: Received message: #{inspect(message)}")

    if state.registry do
      Channel.Registry.handle_message(state.registry, message)
    else
      Logger.error("[#{__MODULE__}]: No registry found")
    end

    {:noreply, state}
  end

  defp version do
    if version = Application.spec(:supabase_potion)[:vsn] do
      List.to_string(version)
    end
  end

  defp generate_join_ref do
    "msg:" <> (:crypto.strong_rand_bytes(10) |> Base.encode16(case: :lower))
  end

  defp send_message_to_topic(topic, payload, state) do
    message_ref = payload[:ref] || generate_join_ref()

    message = %{
      topic: topic,
      event: payload[:event] || "phx_message",
      payload: payload[:payload] || %{},
      ref: message_ref
    }

    {:ok, encoded} = Message.encode(message)
    :ok = :gun.ws_send(state.socket, state.stream_ref, {:text, encoded})

    {:ok, message_ref}
  end
end

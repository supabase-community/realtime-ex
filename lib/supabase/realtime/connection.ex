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
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Message

  require Logger

  @max_send_buffer 100

  @typedoc """
  Connection state.
  """
  @type state :: %{
          url: String.t(),
          params: map(),
          registry: atom() | pid(),
          store: atom() | pid(),
          socket: pid() | nil,
          status: Realtime.connection_state(),
          stream_ref: reference() | nil,
          reconnect_timer: reference() | nil,
          heartbeat_timer: reference() | nil,
          heartbeat_interval: pos_integer(),
          pending_heartbeat_ref: Realtime.ref() | nil,
          reconnect_attempts: non_neg_integer(),
          reconnect_after_ms: (non_neg_integer() -> pos_integer()),
          send_buffer: :queue.queue(),
          send_buffer_size: non_neg_integer(),
          push_buffers: %{String.t() => :queue.queue()},
          http_fallback: boolean(),
          access_token_fn: (-> {:ok, String.t()} | {:error, term()}) | {module(), atom(), list()} | nil,
          custom_params: map()
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
    _ = Keyword.fetch!(opts, :store)

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
  Sends a message on a channel with acknowledgment support.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  * `payload` - The message payload
  * `ack_ref` - The acknowledgment reference
  """
  @spec send_message_with_ack(GenServer.server(), Channel.t(), map(), String.t()) :: :ok | {:error, term()}
  def send_message_with_ack(server, %Channel{} = channel, payload, ack_ref) do
    GenServer.call(server, {:send_message_with_ack, channel, payload, ack_ref})
  end

  @doc """
  Updates the authentication token for all channels.

  ## Parameters

  * `server` - The server PID or name
  * `token` - The new authentication token
  """
  @spec set_auth(GenServer.server(), String.t()) :: :ok | {:error, term()}
  def set_auth(server, token) when is_binary(token) do
    GenServer.call(server, {:set_auth, token})
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
    store = opts[:store]
    registry = opts[:registry]
    heartbeat_interval = opts[:heartbeat_interval] || to_timeout(second: 30)
    reconnect_function = opts[:reconnect_after_ms] || (&default_reconnect_after_ms/1)

    state = %{
      client: client,
      registry: registry,
      store: store,
      socket: nil,
      status: :closed,
      stream_ref: nil,
      reconnect_timer: nil,
      heartbeat_timer: nil,
      heartbeat_interval: heartbeat_interval,
      pending_heartbeat_ref: nil,
      reconnect_attempts: 0,
      reconnect_after_ms: reconnect_function,
      send_buffer: :queue.new(),
      send_buffer_size: 0,
      push_buffers: %{},
      http_fallback: opts[:http_fallback] || false,
      access_token_fn: opts[:access_token_fn],
      custom_params: opts[:params] || %{}
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
    token = resolve_access_token(state, client)
    uri = build_url(client, state.custom_params)
    path = uri.path <> if(uri.query == "", do: "", else: "?" <> uri.query)

    headers = [
      {~c"user-agent", ~c"SupabasePotion/#{version()}"},
      {~c"x-client-info", ~c"supabase-realtime-elixir/#{version()}"},
      {~c"authorization", ~c"Bearer #{token}"}
    ]

    stream_ref = :gun.ws_upgrade(socket, path, headers)

    {:noreply, %{state | stream_ref: stream_ref}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state.status, state}

  def handle_call({:send_message, channel, payload}, _from, %{status: status} = state) when status != :open do
    if state.http_fallback and broadcast_payload?(payload) do
      result = try_http_fallback(state, channel, payload)
      {:reply, result, state}
    else
      Logger.debug("[#{inspect(__MODULE__)}]: Buffering message for channel: #{channel.topic}")
      state = enqueue_send_buffer(state, channel, payload)
      {:reply, :ok, state}
    end
  end

  def handle_call({:send_message, channel, payload}, _from, state) do
    state = maybe_push_buffer_or_send(channel, payload, state)
    {:reply, :ok, state}
  end

  def handle_call({:send_message_with_ack, channel, payload, _ack_ref}, _from, %{status: status} = state)
      when status != :open do
    Logger.debug("[#{inspect(__MODULE__)}]: Buffering ack message for channel: #{channel.topic}")
    state = enqueue_send_buffer(state, channel, payload)
    {:reply, :ok, state}
  end

  def handle_call({:send_message_with_ack, channel, payload, ack_ref}, {caller, _tag}, state) do
    {:ok, updated_channel} = Store.add_pending_ack(state.store, channel, ack_ref, caller)
    state = maybe_push_buffer_or_send(updated_channel, payload, state)
    {:reply, :ok, state}
  end

  def handle_call({:set_auth, _token}, _from, %{socket: nil, status: status} = state) when status != :open do
    Logger.warning("[#{inspect(__MODULE__)}]: Not connected, ignoring auth token update")

    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:set_auth, token}, _from, state) do
    # Get all channels from the store and update their auth tokens
    channels = Store.all(state.store)

    # For each channel, send an access_token message
    Enum.each(channels, fn channel ->
      if Channel.joined?(channel) do
        message = Message.access_token_message(channel, token)
        :ok = send_message_to_topic(channel, message, state)
      end
    end)

    {:reply, :ok, state}
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
    {:stop, {:error, {:failed_to_upgrade, status, headers}}, %{state | status: :closed}}
  end

  def handle_info({:gun_error, socket, stream, reason}, %{socket: socket, stream_ref: stream} = state) do
    Logger.error("[#{__MODULE__}]: Connection error: #{inspect(reason)}")
    {:stop, {:error, reason}, %{state | status: :closed}}
  end

  def handle_info({:gun_upgrade, socket, stream, ["websocket"], _headers}, %{socket: socket, stream_ref: stream} = state) do
    Logger.debug("[#{__MODULE__}]: Connection upgraded to websocket with success")
    {:noreply, flush_send_buffer(transition_status(state, :open))}
  end

  def handle_info({:gun_down, socket, _protocol, reason, _killed_streams}, %{socket: socket} = state) do
    Logger.debug("[#{__MODULE__}]: Connection down: #{inspect(reason)}")
    updated_state = transition_status(state, :closed)

    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    reconnect_timer = schedule_reconnect(updated_state)

    {:noreply, %{updated_state | heartbeat_timer: nil, reconnect_timer: reconnect_timer}}
  end

  def handle_info({:gun_ws, socket, stream, {:text, data}}, %{socket: socket, stream_ref: stream} = state) do
    case Message.decode(data) do
      {:ok, message} ->
        handle_ws_message(message, state)

      {:error, reason} ->
        Logger.error("[#{__MODULE__}]: Failed to decode message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info({:gun_ws, socket, stream, {:close, _, _}}, %{socket: socket, stream_ref: stream} = state) do
    Logger.debug("[#{__MODULE__}]: WebSocket closed")
    {:noreply, transition_status(state, :closed)}
  end

  def handle_info(:heartbeat, %{socket: nil, status: status} = state) when status != :open do
    {:noreply, state}
  end

  def handle_info(:heartbeat, state) do
    heartbeat_ref = generate_join_ref()

    message = Message.heartbeat_message()
    send_message_to_topic("phoenix", Map.put(message, :ref, heartbeat_ref), state)
    heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

    {:noreply, %{state | heartbeat_timer: heartbeat_timer, pending_heartbeat_ref: heartbeat_ref}}
  end

  def handle_info(:reconnect, state) do
    case connect(%{state | reconnect_attempts: state.reconnect_attempts + 1}) do
      {:ok, socket, updated_state} ->
        heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

        {:noreply, %{updated_state | socket: socket, heartbeat_timer: heartbeat_timer, reconnect_timer: nil}}

      {:error, _reason, updated_state} ->
        reconnect_timer = schedule_reconnect(updated_state)

        {:noreply, %{updated_state | reconnect_timer: reconnect_timer}}
    end
  end

  def handle_info({:ack_timeout, ack_ref}, state) do
    Logger.debug("[#{__MODULE__}]: Acknowledgment timeout for: #{ack_ref}")

    case Store.handle_ack_timeout(state.store, ack_ref) do
      {:ok, caller} ->
        send(caller, {:ack_timeout, ack_ref})
        Logger.debug("[#{__MODULE__}]: Sent ack timeout notification to #{inspect(caller)}")

      :error ->
        Logger.warning("[#{__MODULE__}]: Timeout for unknown ack reference: #{ack_ref}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:channel_joined, topic}, state) do
    {:noreply, flush_push_buffer(state, topic)}
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

  # State transition with notification

  defp transition_status(state, new_status) do
    old = state.status

    if old != new_status and state.registry do
      GenServer.cast(state.registry, {:connection_state_changed, old, new_status})
    end

    %{state | status: new_status}
  end

  # Buffer helpers

  defp enqueue_send_buffer(state, channel, payload) do
    {buffer, size} =
      if state.send_buffer_size >= @max_send_buffer do
        {_, q} = :queue.out(state.send_buffer)
        {q, state.send_buffer_size}
      else
        {state.send_buffer, state.send_buffer_size + 1}
      end

    %{state | send_buffer: :queue.in({channel, payload}, buffer), send_buffer_size: size}
  end

  defp flush_send_buffer(state) do
    state.send_buffer
    |> :queue.to_list()
    |> Enum.each(fn {channel, payload} ->
      send_message_to_topic(channel, payload, state)
    end)

    %{state | send_buffer: :queue.new(), send_buffer_size: 0}
  end

  defp enqueue_push_buffer(state, topic, channel, payload) do
    queue = Map.get(state.push_buffers, topic, :queue.new())
    updated = :queue.in({channel, payload}, queue)
    %{state | push_buffers: Map.put(state.push_buffers, topic, updated)}
  end

  defp flush_push_buffer(state, topic) do
    case Map.pop(state.push_buffers, topic) do
      {nil, _} ->
        state

      {queue, rest} ->
        queue
        |> :queue.to_list()
        |> Enum.each(fn {channel, payload} ->
          send_message_to_topic(channel, payload, state)
        end)

        %{state | push_buffers: rest}
    end
  end

  defp maybe_push_buffer_or_send(channel, payload, state) do
    case Store.find_by_ref(state.store, channel.ref) do
      {:ok, latest} when latest.state == :joining ->
        enqueue_push_buffer(state, channel.topic, channel, payload)

      _ ->
        send_message_to_topic(channel, payload, state)
        state
    end
  end

  # Token resolution

  defp resolve_access_token(%{access_token_fn: nil}, client) do
    client.access_token || client.apikey
  end

  defp resolve_access_token(%{access_token_fn: fun}, client) when is_function(fun, 0) do
    case fun.() do
      {:ok, token} -> token
      {:error, _} -> client.access_token || client.apikey
    end
  end

  defp resolve_access_token(%{access_token_fn: {mod, fun, args}}, client) do
    case apply(mod, fun, args) do
      {:ok, token} -> token
      {:error, _} -> client.access_token || client.apikey
    end
  end

  # HTTP fallback

  defp broadcast_payload?(%{event: "broadcast"}), do: true
  defp broadcast_payload?(%{payload: %{type: "broadcast"}}), do: true
  defp broadcast_payload?(_), do: false

  defp try_http_fallback(state, channel, payload) do
    {:ok, client} = state.client.get_client()
    token = resolve_access_token(state, client)
    event = get_in(payload, [:payload, :event]) || payload[:event] || "broadcast"
    inner_payload = get_in(payload, [:payload, :payload]) || payload[:payload] || %{}

    Realtime.HTTP.broadcast(client, token, channel.topic, event, inner_payload)
  end

  # Private helper functions

  defp connect(state) do
    {:ok, client} = state.client.get_client()
    uri = build_url(client, state.custom_params)

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

  defp build_url(%Supabase.Client{} = client, custom_params) do
    base_params = %{apikey: client.api_key, vsn: "1.0.0"}
    query = base_params |> Map.merge(custom_params) |> URI.encode_query()

    client.realtime_url
    |> URI.new!()
    |> URI.append_path("/websocket")
    |> URI.append_query(query)
    |> update_uri_scheme()
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

  @max_backoff to_timeout(second: 10)
  @base_backoff to_timeout(second: 1)

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

  defp handle_ws_message(%{"event" => "phx_reply", "payload" => %{"status" => "ok"}, "ref" => ack_ref}, state)
       when is_binary(ack_ref) and binary_part(ack_ref, 0, 4) == "ack:" do
    Logger.debug("[#{__MODULE__}]: Received acknowledgment reply: #{ack_ref}")

    # Find the channel and notify the caller
    case Store.handle_ack_received(state.store, ack_ref) do
      {:ok, caller} ->
        send(caller, {:ack_received, ack_ref})
        Logger.debug("[#{__MODULE__}]: Sent ack notification to #{inspect(caller)}")

      :error ->
        Logger.warning("[#{__MODULE__}]: Received ack for unknown reference: #{ack_ref}")
    end

    {:noreply, state}
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
    "msg:" <> (10 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  defp send_message_to_topic(channel, payload, state) do
    channel = ensure_latest_channel(channel, state)
    message_ref = payload[:ref] || generate_join_ref()

    message = %{
      topic: channel.topic,
      event: payload[:event] || "phx_message",
      payload: payload[:payload] || %{},
      ref: message_ref
    }

    Logger.debug("[#{__MODULE__}]: Sending message: #{inspect(message)}")

    {:ok, encoded} = Message.encode(message)
    :ok = :gun.ws_send(state.socket, state.stream_ref, {:text, encoded})
    {:ok, _} = Store.update_join_ref(state.store, channel, message_ref)

    :ok
  end

  defp ensure_latest_channel(channel, state) do
    case Store.find_by_ref(state.store, channel.ref) do
      {:ok, channel} -> channel
      _ -> channel
    end
  end
end

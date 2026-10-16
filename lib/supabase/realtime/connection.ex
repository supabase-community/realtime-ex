defmodule Supabase.Realtime.Connection do
  @moduledoc """
  WebSocket connection manager for Supabase Realtime.

  Handles the full lifecycle of a WebSocket connection to the Supabase
  Realtime service.

  ## Responsibilities

  * Establishing and maintaining the WebSocket connection.
  * Sending and receiving messages.
  * Reconnection with stepped backoff. The default delays are 1s, 2s, 5s and
    then 10s per attempt. You can supply your own function with the
    `:reconnect_after_ms` option.
  * Heartbeats to detect connection health. A heartbeat that goes unanswered
    by the next tick forces the connection closed and a reconnect.

  ## Buffers

  Messages sent while the connection is down are placed in a **send buffer**
  (up to 100 entries). Once the WebSocket upgrades, the buffer is flushed in
  order. Messages sent while a channel is still joining go into a per-topic
  **push buffer** that flushes when the channel reaches the `:joined` state.

  ## HTTP Fallback

  When `:http_fallback` is `true` and the WebSocket is not open, broadcast
  messages are delivered through the REST API instead of being buffered.
  Other message types are still buffered normally. See `Supabase.Realtime.HTTP`
  for details.

  ## Token Resolution

  The access token used for the WebSocket upgrade and join payloads is
  resolved in this order:

  1. The `:access_token_fn` option, if provided and returns `{:ok, token}`.
  2. The token persisted by `set_auth/2`, if set.
  3. `client.access_token`, if set on the `%Supabase.Client{}` struct.
  4. `client.api_key` as a last resort.

  ## TLS

  For `wss` URLs the connection verifies the server certificate against the
  OS trust store (`verify: :verify_peer`, hostname check included). Hosts
  without an OS trust store, or with a private CA, can override the defaults
  with the `:tls_opts` start option (merged over them).

  ## Custom Params

  Any map passed as `:params` is merged into the WebSocket URL query string
  alongside the default `apikey` and `vsn` params.
  """

  use GenServer

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Message
  alias Supabase.Realtime.Serializer

  require Logger

  @max_send_buffer 100

  @typedoc """
  Connection state.
  """
  @type state :: %{
          client: Supabase.Client.t(),
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
          access_token: String.t() | nil,
          access_token_fn: (-> {:ok, String.t()} | {:error, term()}) | {module(), atom(), list()} | nil,
          tls_opts: keyword() | nil,
          custom_params: map(),
          serializer: module(),
          vsn: String.t(),
          serializer_opts: keyword()
        }

  # Client API

  @doc """
  Starts the connection manager.

  ## Options

  * `:name` - Optional registration name
  * `:registry` - Registry process name
  * `:client` - A `%Supabase.Client{}` struct
  * `:heartbeat_interval` - Interval in milliseconds between heartbeats
  * `:reconnect_after_ms` - Function that returns reconnection delay based on attempts
  * `:tls_opts` - Keyword list merged over the default TLS options (which
    verify the peer certificate against the OS trust store)
  * `:vsn` - Realtime protocol version negotiated in the websocket query
    string ("1.0.0" default, "2.0.0" for array JSON + binary framing)
  * `:serializer` - Module implementing `Supabase.Realtime.Serializer`;
    overrides the vsn-derived default, and you own matching it to the wire
    format the server negotiates for the given vsn
  * `:serializer_opts` - Keyword list forwarded to every serializer
    encode/decode call
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
  Sends the `phx_join` message for a channel.

  Builds the join payload with the current token, assigns a fresh join_ref,
  stores it and sends it directly (never buffered). Returns
  `{:error, :not_connected}` when the socket is not open; the Registry's
  reconnect sweep then delivers the join on `:open`.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  """
  @spec join_channel(GenServer.server(), Channel.t()) :: :ok | {:error, :not_connected | :channel_not_found}
  def join_channel(server, %Channel{} = channel) do
    GenServer.call(server, {:join_channel, channel})
  end

  @doc """
  Sends the `phx_leave` message for a channel with a fresh leave_ref.

  Same not_connected contract as `join_channel/2`.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  """
  @spec leave_channel(GenServer.server(), Channel.t()) :: :ok | {:error, :not_connected | :channel_not_found}
  def leave_channel(server, %Channel{} = channel) do
    GenServer.call(server, {:leave_channel, channel})
  end

  @doc """
  Updates the authentication token for all channels.

  The token is persisted on the connection state and applied on the next
  join/rejoin, so it returns `:ok` even when disconnected. Only joined
  channels get an immediate `access_token` push, and only while the socket is
  open.

  ## Parameters

  * `server` - The server PID or name
  * `token` - The new authentication token
  """
  @spec set_auth(GenServer.server(), String.t()) :: :ok
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
    heartbeat_interval = opts[:heartbeat_interval] || to_timeout(second: 25)
    reconnect_function = opts[:reconnect_after_ms] || (&default_reconnect_after_ms/1)

    {serializer, vsn} =
      case Serializer.resolve(opts) do
        {:ok, serializer, vsn} -> {serializer, vsn}
        {:error, reason} -> raise ArgumentError, "invalid Realtime serializer options: #{inspect(reason)}"
      end

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
      access_token: nil,
      access_token_fn: opts[:access_token_fn],
      tls_opts: opts[:tls_opts],
      custom_params: opts[:params] || %{},
      serializer: serializer,
      vsn: vsn,
      serializer_opts: opts[:serializer_opts] || []
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state) do
      {:ok, socket, updated_state} ->
        {:noreply, %{updated_state | socket: socket}}

      {:error, reason, updated_state} ->
        Logger.error("[#{__MODULE__}]: Failed to connect: #{inspect(reason)}")
        reconnect_timer = schedule_reconnect(updated_state)

        {:noreply, %{updated_state | reconnect_timer: reconnect_timer}}
    end
  end

  def handle_continue(:upgrade, %{socket: socket} = state) do
    token = resolve_access_token(state)
    uri = build_url(state.client, state)
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

  def handle_call(
        {:send_message_with_ack, %Channel{} = channel, payload, ack_ref},
        {caller, _tag},
        %{status: status} = state
      )
      when status != :open do
    channel = ensure_latest_channel(channel, state)

    # the pending ack is registered even when the message is buffered, so the
    # flushed frame is acked after the reconnect
    timer = Process.send_after(self(), {:ack_timeout, ack_ref}, channel.timeout)
    {:ok, _updated} = Store.add_pending_ack(state.store, channel, ack_ref, caller, timer)

    Logger.debug("[#{inspect(__MODULE__)}]: Buffering ack message for channel: #{channel.topic}")
    state = enqueue_send_buffer(state, channel, payload)
    {:reply, :ok, state}
  end

  def handle_call({:send_message_with_ack, %Channel{} = channel, payload, ack_ref}, {caller, _tag}, state) do
    channel = ensure_latest_channel(channel, state)
    timer = Process.send_after(self(), {:ack_timeout, ack_ref}, channel.timeout)
    {:ok, updated} = Store.add_pending_ack(state.store, channel, ack_ref, caller, timer)
    maybe_push_buffer_or_send(updated, payload, state)
    {:reply, :ok, state}
  end

  def handle_call({:join_channel, channel}, _from, %{status: :open} = state) do
    case Store.find_by_ref(state.store, channel.ref) do
      {:ok, _found} ->
        join_ref = generate_message_ref()
        token = resolve_access_token(state)

        message =
          channel
          |> Message.subscription_message(token)
          |> Map.put(:ref, join_ref)
          |> Map.put(:join_ref, join_ref)

        send_message(message, state)
        {:ok, _updated} = Store.update_join_ref(state.store, channel, join_ref)

        {:reply, :ok, state}

      {:error, :not_found} ->
        {:reply, {:error, :channel_not_found}, state}
    end
  end

  def handle_call({:join_channel, _channel}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:leave_channel, channel}, _from, %{status: :open} = state) do
    case Store.find_by_ref(state.store, channel.ref) do
      {:ok, _found} ->
        leave_ref = generate_message_ref()

        message =
          channel
          |> Message.unsubscribe_message()
          |> Map.put(:ref, leave_ref)
          |> Map.put(:join_ref, channel.join_ref)

        send_message(message, state)
        {:ok, _updated} = Store.update_leave_ref(state.store, channel, leave_ref)

        {:reply, :ok, state}

      {:error, :not_found} ->
        {:reply, {:error, :channel_not_found}, state}
    end
  end

  def handle_call({:leave_channel, _channel}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:set_auth, token}, _from, state) do
    # persisted: resolve_access_token uses it on the next join/rejoin, so the
    # update applies whether or not the socket is up
    state = %{state | access_token: token}

    if state.status == :open do
      for channel <- Store.all(state.store), Channel.joined?(channel) do
        message = Message.access_token_message(channel, token)
        send_message_to_topic(channel, message, state)
      end
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:gun_up, socket, _protocol}, %{socket: socket} = state) do
    Logger.debug("[#{__MODULE__}]: Connection established")
    {:noreply, %{state | reconnect_attempts: 0}, {:continue, :upgrade}}
  end

  def handle_info({:gun_response, socket, _, _, status, _headers}, %{socket: socket} = state) do
    Logger.error("[#{__MODULE__}]: Failed to upgrade to websocket: #{inspect(status)}")
    {:noreply, connection_down(state)}
  end

  def handle_info({:gun_error, socket, _stream, reason}, %{socket: socket} = state) do
    Logger.error("[#{__MODULE__}]: Connection error: #{inspect(reason)}")
    {:noreply, connection_down(state)}
  end

  def handle_info({:gun_upgrade, socket, stream, ["websocket"], _headers}, %{socket: socket, stream_ref: stream} = state) do
    Logger.debug("[#{__MODULE__}]: Connection upgraded to websocket with success")

    state =
      state
      |> transition_status(:open)
      |> Map.put(:reconnect_attempts, 0)
      |> schedule_heartbeat_timer()

    {:noreply, flush_send_buffer(state)}
  end

  def handle_info({:gun_down, socket, _protocol, reason, _killed_streams}, %{socket: socket} = state) do
    Logger.debug("[#{__MODULE__}]: Connection down: #{inspect(reason)}")
    {:noreply, connection_down(state)}
  end

  def handle_info({:gun_ws, socket, stream, {:text, data}}, %{socket: socket, stream_ref: stream} = state) do
    decode_frame({:text, data}, state)
  end

  def handle_info({:gun_ws, socket, stream, {:binary, data}}, %{socket: socket, stream_ref: stream} = state) do
    decode_frame({:binary, data}, state)
  end

  def handle_info({:gun_ws, socket, _stream, {:close, code, _reason}}, %{socket: socket} = state) do
    Logger.debug("[#{__MODULE__}]: WebSocket closed (code: #{inspect(code)})")
    {:noreply, connection_down(state)}
  end

  def handle_info({:DOWN, _monitor_ref, :process, socket, reason}, %{socket: socket} = state) do
    Logger.debug("[#{__MODULE__}]: Gun process down: #{inspect(reason)}")
    {:noreply, connection_down(state)}
  end

  def handle_info(:heartbeat, %{status: :open} = state) do
    if state.pending_heartbeat_ref do
      # previous heartbeat unanswered: dead connection. Phoenix forces close +
      # reconnect here.
      Logger.warning("[#{__MODULE__}]: Heartbeat not acknowledged, forcing reconnect")
      {:noreply, connection_down(state)}
    else
      heartbeat_ref = generate_message_ref()

      message = Map.put(Message.heartbeat_message(), :ref, heartbeat_ref)

      send_message(message, state)

      {:noreply,
       %{
         state
         | pending_heartbeat_ref: heartbeat_ref,
           heartbeat_timer: Process.send_after(self(), :heartbeat, state.heartbeat_interval)
       }}
    end
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    case connect(%{state | reconnect_attempts: state.reconnect_attempts + 1}) do
      {:ok, socket, updated_state} ->
        {:noreply, %{updated_state | socket: socket, reconnect_timer: nil}}

      {:error, _reason, updated_state} ->
        reconnect_timer = schedule_reconnect(updated_state)

        {:noreply, %{updated_state | reconnect_timer: reconnect_timer}}
    end
  end

  # Stale messages from a previous gun process that a reconnect replaced, and
  # :DOWN notices for every reaped socket, are ignored.
  def handle_info({:gun_up, _socket, _protocol}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale gun_up message")
    {:noreply, state}
  end

  def handle_info({:gun_response, _socket, _stream_ref, _fin, _status, _headers}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale gun_response message")
    {:noreply, state}
  end

  def handle_info({:gun_error, _socket, _stream, reason}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale gun_error message: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:gun_upgrade, _socket, _stream, _protocols, _headers}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale gun_upgrade message")
    {:noreply, state}
  end

  def handle_info({:gun_down, _socket, _protocol, reason, _killed_streams}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale gun_down message: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info({:gun_ws, _socket, _stream, {:text, _data}}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale websocket text frame")
    {:noreply, state}
  end

  def handle_info({:gun_ws, _socket, _stream, {:binary, _data}}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale websocket binary frame")
    {:noreply, state}
  end

  def handle_info({:gun_ws, _socket, _stream, {:close, _code, _reason}}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring stale websocket close frame")
    {:noreply, state}
  end

  def handle_info({:DOWN, _monitor_ref, :process, _socket, _reason}, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring :DOWN for a stale socket")
    {:noreply, state}
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

  # Single down path shared by gun_down, the monitored gun :DOWN, gun_error,
  # the websocket close frame, a dead heartbeat and a failed upgrade: cancel
  # the heartbeat timer, clear the socket/stream refs, reap the gun process
  # (retry: 0 means it never reconnects on its own and would otherwise leak),
  # transition to :closed and schedule a reconnect.
  defp connection_down(state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    if socket = state.socket do
      if Process.alive?(socket), do: :gun.close(socket)
    end

    state = %{
      state
      | socket: nil,
        stream_ref: nil,
        heartbeat_timer: nil,
        pending_heartbeat_ref: nil
    }

    state = transition_status(state, :closed)
    reconnect_timer = schedule_reconnect(state)
    %{state | reconnect_timer: reconnect_timer}
  end

  # Exactly one heartbeat timer exists at a time: scheduled only when the
  # status becomes :open, cancelled in every down path.
  defp schedule_heartbeat_timer(state) do
    if state.heartbeat_timer, do: Process.cancel_timer(state.heartbeat_timer)

    %{
      state
      | heartbeat_timer: Process.send_after(self(), :heartbeat, state.heartbeat_interval),
        pending_heartbeat_ref: nil
    }
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

  # order: access_token_fn (0-arity fun or MFA) -> persisted set_auth token ->
  # client.access_token -> client.api_key. A failing fn falls through to the
  # rest of the chain.
  @spec resolve_access_token(state()) :: String.t() | nil
  defp resolve_access_token(state) do
    case fetch_token_from_fn(state.access_token_fn) do
      {:ok, token} -> token
      _ -> state.access_token || state.client.access_token || state.client.api_key
    end
  end

  defp fetch_token_from_fn(nil), do: :no_fn
  defp fetch_token_from_fn(fun) when is_function(fun, 0), do: fun.()
  defp fetch_token_from_fn({mod, fun, args}), do: apply(mod, fun, args)

  # HTTP fallback

  defp broadcast_payload?(%{event: "broadcast"}), do: true
  defp broadcast_payload?(%{payload: %{type: "broadcast"}}), do: true
  defp broadcast_payload?(_), do: false

  defp try_http_fallback(state, channel, payload) do
    token = resolve_access_token(state)
    event = get_in(payload, [:payload, :event]) || payload[:event] || "broadcast"
    inner_payload = get_in(payload, [:payload, :payload]) || payload[:payload] || %{}

    Realtime.HTTP.broadcast(state.client, token, channel.topic, event, inner_payload)
  end

  # Private helper functions

  defp connect(state) do
    client = state.client
    uri = build_url(client, state)

    host = String.to_charlist(uri.host)
    port = uri.port || if uri.scheme == "wss", do: 443, else: 80

    case :gun.open(host, port, gun_opts(uri, state)) do
      {:ok, socket} ->
        Process.monitor(socket)

        {:ok, socket, %{state | status: :connecting}}

      {:error, reason} ->
        Logger.error("[#{__MODULE__}]: Failed to connect: #{inspect(reason)}")
        {:error, reason, %{state | status: :closed}}
    end
  end

  # retry: 0 is required: gun's default is retry: 5, which is a second,
  # competing reconnect loop fighting this GenServer's own :reconnect timer.
  defp gun_opts(%URI{scheme: scheme, host: host}, state) do
    transport = if scheme == "wss", do: :tls, else: :tcp

    base = %{
      protocols: [:http],
      http_opts: %{version: :"HTTP/1.1"},
      transport: transport,
      retry: 0
    }

    if transport == :tls do
      Map.put(base, :tls_opts, default_tls_opts(host, state))
    else
      base
    end
  end

  # Chain validation without the hostname check accepts any CA-signed cert
  # for the wrong host. The :tls_opts start option is merged over the
  # defaults so hosts without an OS trust store can override.
  defp default_tls_opts(host, state) do
    Keyword.merge(
      [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 3,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ],
      state.tls_opts || []
    )
  end

  # the negotiated vsn is written after the custom params merge so it is
  # authoritative: a user vsn in :params can no longer desync the wire format
  # from the serializer
  defp build_url(%Supabase.Client{} = client, state) do
    query =
      %{apikey: client.api_key}
      |> Map.merge(state.custom_params)
      |> Map.put(:vsn, state.vsn)
      |> URI.encode_query()

    client.realtime_url
    |> URI.new!()
    |> URI.append_path("/websocket")
    |> URI.append_query(query)
    |> update_uri_scheme()
  end

  defp update_uri_scheme(%URI{scheme: "http"} = uri), do: %{uri | scheme: "ws"}
  defp update_uri_scheme(%URI{scheme: "https"} = uri), do: %{uri | scheme: "wss"}
  defp update_uri_scheme(uri), do: uri

  defp schedule_reconnect(state) do
    # tries is 1-based (the number of the upcoming attempt). Matches
    # realtime-js RECONNECT_INTERVALS[tries - 1] || 10000.
    reconnect_time = state.reconnect_after_ms.(state.reconnect_attempts + 1)
    Process.send_after(self(), :reconnect, reconnect_time)
  end

  @reconnect_intervals [1000, 2000, 5000, 10_000]
  @default_reconnect_fallback 10_000

  defp default_reconnect_after_ms(tries), do: Enum.at(@reconnect_intervals, tries - 1, @default_reconnect_fallback)

  # Both frame opcodes route through the negotiated serializer; decode
  # failures are logged and dropped (the Registry never sees a bad frame).
  defp decode_frame(frame, state) do
    case state.serializer.decode(frame, state.serializer_opts) do
      {:ok, message} ->
        handle_ws_message(message, state)

      {:error, reason} ->
        Logger.error("[#{__MODULE__}]: failed to decode frame: #{inspect(reason)}")
        {:noreply, state}
    end
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

  defp generate_message_ref do
    "msg:" <> (10 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower))
  end

  defp send_message_to_topic(channel, payload, state) do
    channel = ensure_latest_channel(channel, state)
    message_ref = payload[:ref] || generate_message_ref()

    message = %{
      topic: channel.topic,
      event: payload[:event] || "phx_message",
      payload: payload[:payload] || %{},
      ref: message_ref,
      # protocol requires join_ref on channel pushes (heartbeat omits it)
      join_ref: channel.join_ref
    }

    Logger.debug("[#{__MODULE__}]: Sending message: #{inspect(message)}")

    send_message(message, state)
  end

  # Encode failures are log-and-drop: they are programming or configuration
  # errors (unencodable payload, oversized field), not transient conditions a
  # caller could retry, so call replies keep their :ok contract.
  defp send_message(message, state) do
    case state.serializer.encode(message, state.serializer_opts) do
      {:ok, frame} ->
        :ok = :gun.ws_send(state.socket, state.stream_ref, frame)
        :ok

      {:error, reason} ->
        Logger.error("[#{__MODULE__}]: failed to encode message on topic #{message.topic}: #{inspect(reason)}")

        {:error, reason}
    end
  end

  defp ensure_latest_channel(channel, state) do
    case Store.find_by_ref(state.store, channel.ref) do
      {:ok, channel} -> channel
      _ -> channel
    end
  end
end

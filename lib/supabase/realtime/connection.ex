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
          ref: non_neg_integer(),
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
  * `:url` - WebSocket endpoint URL
  * `:params` - Connection parameters
  * `:heartbeat_interval` - Interval in milliseconds between heartbeats
  * `:reconnect_after_ms` - Function that returns reconnection delay based on attempts
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Sends a message on a channel.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  * `payload` - The message payload
  * `opts` - Send options
  """
  @spec send_message(GenServer.server(), Channel.t(), map(), keyword()) :: :ok | {:error, term()}
  def send_message(server, %Channel{} = channel, payload, opts \\ []) do
    GenServer.call(server, {:send_message, channel, payload, opts})
  end

  @doc """
  Gets the current connection state.

  ## Parameters

  * `server` - The server PID or name
  """
  @spec state(GenServer.server()) :: Realtime.connection_state()
  def state(server) do
    GenServer.call(server, :state)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    registry = opts[:registry]
    url = opts[:url]
    params = opts[:params] || %{}
    heartbeat_interval = opts[:heartbeat_interval] || :timer.seconds(30)
    reconnect_function = opts[:reconnect_after_ms] || (&default_reconnect_after_ms/1)

    state = %{
      url: url,
      params: params,
      registry: registry,
      socket: nil,
      status: :closed,
      ref: 0,
      reconnect_timer: nil,
      heartbeat_timer: nil,
      heartbeat_interval: heartbeat_interval,
      pending_heartbeat_ref: nil,
      reconnect_attempts: 0,
      reconnect_after_ms: reconnect_function
    }

    # Schedule immediate connection
    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    # Start connection process
    case connect(state) do
      {:ok, socket, updated_state} ->
        # Schedule the first heartbeat
        heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

        {:noreply, %{updated_state | socket: socket, heartbeat_timer: heartbeat_timer}}

      {:error, reason, updated_state} ->
        # Schedule reconnection
        reconnect_timer = schedule_reconnect(updated_state)

        {:noreply, %{updated_state | reconnect_timer: reconnect_timer}}
    end
  end

  @impl true
  def handle_call(:state, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:send_message, channel, payload, opts}, _from, state) do
    result =
      if state.status == :open and state.socket do
        # Prepare the message
        ref = make_ref(state)

        message = %{
          topic: channel.topic,
          event: payload[:event] || "phx_message",
          payload: payload[:payload] || %{},
          ref: ref
        }

        # Serialize and send the message
        encoded = Message.encode(message)

        case :gun.ws_send(state.socket, {:text, encoded}) do
          :ok ->
            {:ok, ref}

          error ->
            {:error, error}
        end
      else
        {:error, :not_connected}
      end

    {:reply, result, %{state | ref: state.ref + 1}}
  end

  @impl true
  def handle_info({:gun_up, socket, _protocol}, %{socket: socket} = state) do
    Logger.debug("Supabase.Realtime.Connection: Connection established")

    # Update connection status
    updated_state = %{state | status: :open, reconnect_attempts: 0}

    # Schedule heartbeat
    heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

    {:noreply, %{updated_state | heartbeat_timer: heartbeat_timer}}
  end

  @impl true
  def handle_info(
        {:gun_down, socket, _protocol, reason, _killed_streams},
        %{socket: socket} = state
      ) do
    Logger.debug("Supabase.Realtime.Connection: Connection down: #{inspect(reason)}")

    # Update connection status
    updated_state = %{state | status: :closed}

    # Cancel heartbeat timer
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    # Schedule reconnection
    reconnect_timer = schedule_reconnect(updated_state)

    {:noreply, %{updated_state | heartbeat_timer: nil, reconnect_timer: reconnect_timer}}
  end

  @impl true
  def handle_info({:gun_ws, socket, _stream, {:text, data}}, %{socket: socket} = state) do
    # Decode the message
    case Message.decode(data) do
      {:ok, message} ->
        # Handle the message
        handle_ws_message(message, state)

      {:error, reason} ->
        Logger.error("Supabase.Realtime.Connection: Failed to decode message: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:heartbeat, state) do
    # Send heartbeat if connected
    updated_state =
      if state.status == :open and state.socket do
        # Send heartbeat message
        ref = make_ref(state)

        heartbeat_message = %{
          topic: "phoenix",
          event: "heartbeat",
          payload: %{},
          ref: ref
        }

        encoded = Message.encode(heartbeat_message)
        :gun.ws_send(state.socket, {:text, encoded})

        # Update state with pending heartbeat ref
        %{state | ref: state.ref + 1, pending_heartbeat_ref: ref}
      else
        state
      end

    # Schedule next heartbeat
    heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

    {:noreply, %{updated_state | heartbeat_timer: heartbeat_timer}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    # Attempt to reconnect
    case connect(%{state | reconnect_attempts: state.reconnect_attempts + 1}) do
      {:ok, socket, updated_state} ->
        # Connection successful
        heartbeat_timer = schedule_heartbeat(state.heartbeat_interval)

        {:noreply,
         %{updated_state | socket: socket, heartbeat_timer: heartbeat_timer, reconnect_timer: nil}}

      {:error, _reason, updated_state} ->
        # Schedule another reconnection attempt
        reconnect_timer = schedule_reconnect(updated_state)

        {:noreply, %{updated_state | reconnect_timer: reconnect_timer}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    # Close WebSocket connection if open
    if state.status == :open and state.socket do
      :gun.close(state.socket)
    end

    # Cancel timers
    if state.heartbeat_timer do
      Process.cancel_timer(state.heartbeat_timer)
    end

    if state.reconnect_timer do
      Process.cancel_timer(state.reconnect_timer)
    end

    :ok
  end

  # Private helper functions

  # Establish WebSocket connection
  defp connect(state) do
    # Build the URL with parameters
    url = build_url(state.url, state.params)

    # Parse the URL
    uri = URI.parse(url)

    # Get the host and port
    host = String.to_charlist(uri.host)
    port = uri.port || if uri.scheme == "wss", do: 443, else: 80

    # Start gun
    gun_opts = %{
      protocols: [:http],
      transport: if(uri.scheme == "wss", do: :tls, else: :tcp),
      transport_opts: [
        verify: :verify_none
      ]
    }

    case :gun.open(host, port, gun_opts) do
      {:ok, conn_pid} ->
        # Wait for gun to connect
        case :gun.await_up(conn_pid, 5000) do
          {:ok, _protocol} ->
            # Upgrade to WebSocket
            ws_opts = %{protocols: [{:http, :websocket}]}
            path = uri.path <> if(uri.query, do: "?" <> uri.query, else: "")

            :gun.ws_upgrade(conn_pid, path, [], ws_opts)

            # Return success
            {:ok, conn_pid, %{state | status: :connecting}}

          {:error, reason} ->
            Logger.error("Supabase.Realtime.Connection: Failed to connect: #{inspect(reason)}")
            {:error, reason, %{state | status: :closed}}
        end

      {:error, reason} ->
        Logger.error(
          "Supabase.Realtime.Connection: Failed to open connection: #{inspect(reason)}"
        )

        {:error, reason, %{state | status: :closed}}
    end
  end

  # Build the WebSocket URL with parameters
  defp build_url(base_url, params) do
    query = URI.encode_query(Map.put(params, :vsn, "1.0.0"))
    base_url <> "?" <> query
  end

  # Generate a new message reference
  defp make_ref(state) do
    "#{state.ref + 1}"
  end

  # Schedule heartbeat
  defp schedule_heartbeat(interval) do
    Process.send_after(self(), :heartbeat, interval)
  end

  # Schedule reconnection with exponential backoff
  defp schedule_reconnect(state) do
    reconnect_time = state.reconnect_after_ms.(state.reconnect_attempts)
    Process.send_after(self(), :reconnect, reconnect_time)
  end

  # Default reconnection backoff function
  defp default_reconnect_after_ms(tries) do
    [1_000, 2_000, 5_000, 10_000]
    |> Enum.at(tries - 1, 10_000)
  end

  # Handle WebSocket messages
  defp handle_ws_message(message, state) do
    # Check if this is a heartbeat response
    is_heartbeat_reply =
      message["topic"] == "phoenix" and
        message["event"] == "phx_reply" and
        message["ref"] == state.pending_heartbeat_ref

    updated_state =
      if is_heartbeat_reply do
        # Clear pending heartbeat ref
        %{state | pending_heartbeat_ref: nil}
      else
        # Forward message to registry
        if state.registry do
          Channel.Registry.handle_message(state.registry, message)
        end

        state
      end

    {:noreply, updated_state}
  end
end

defmodule Supabase.Realtime.Channel.Registry do
  @moduledoc """
  Registry for managing Realtime channel subscriptions.

  This module is responsible for tracking active channels and their subscriptions,
  and for routing messages to the appropriate callback functions when events
  are received.
  """

  use GenServer

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel

  require Logger

  @typedoc """
  Registry state holding all subscription information.
  """
  @type state :: %{
          channels: map(),
          module: module(),
          pending_events: list(),
          presence_state: map()
        }

  # Client API

  defguard is_database_event(event) when event in ~w(INSERT UPDATE DELETE)

  @doc """
  Starts the channel registry process.

  ## Options

  * `:name` - Optional registration name
  * `:module` - The callback module for event handling
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = opts[:name] || __MODULE__
    module = Keyword.fetch!(opts, :module)

    GenServer.start_link(__MODULE__, %{module: module}, name: name)
  end

  @doc """
  Creates a new channel in the registry.

  ## Parameters

  * `server` - The server PID or name
  * `topic` - The topic to subscribe to
  * `opts` - Channel options
  """
  @spec create_channel(GenServer.server(), String.t(), keyword()) ::
          {:ok, Channel.t()} | {:error, term()}
  def create_channel(server, topic, opts \\ []) do
    GenServer.call(server, {:create_channel, topic, opts})
  end

  @doc """
  Subscribes to events on a channel.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  * `type` - The event type
  * `filter` - The event filter
  """
  @spec subscribe(GenServer.server(), Channel.t(), String.t(), map() | keyword()) ::
          :ok | {:error, term()}
  def subscribe(server, %Channel{} = channel, type, filter) do
    GenServer.call(server, {:subscribe, channel, type, filter})
  end

  @doc """
  Unsubscribes from a channel.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel to unsubscribe from
  """
  @spec unsubscribe(GenServer.server(), Channel.t()) :: :ok | {:error, term()}
  def unsubscribe(server, %Channel{} = channel) do
    GenServer.call(server, {:unsubscribe, channel})
  end

  @doc """
  Removes all channel subscriptions.

  ## Parameters

  * `server` - The server PID or name
  """
  @spec remove_all_channels(GenServer.server()) :: :ok | {:error, term()}
  def remove_all_channels(server) do
    GenServer.call(server, :remove_all_channels)
  end

  @doc """
  Handles a message from the server.

  ## Parameters

  * `server` - The server PID or name
  * `message` - The message to handle
  """
  @spec handle_message(GenServer.server(), Realtime.realtime_message()) :: :ok
  def handle_message(server, message) do
    GenServer.cast(server, {:handle_message, message})
  end

  @doc """
  Updates the join reference for a channel.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  * `join_ref` - The join reference
  """
  @spec update_join_ref(GenServer.server(), Channel.t(), Realtime.ref()) :: :ok
  def update_join_ref(server, %Channel{} = channel, join_ref) do
    GenServer.cast(server, {:update_join_ref, channel, join_ref})
  end

  @doc """
  Updates the state of a channel.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  * `state` - The new state
  """
  @spec update_channel_state(GenServer.server(), Channel.t(), Realtime.channel_state()) :: :ok
  def update_channel_state(server, %Channel{} = channel, state) do
    GenServer.cast(server, {:update_channel_state, channel, state})
  end

  # Server callbacks

  @impl true
  def init(init_arg) do
    state = %{
      channels: %{},
      module: init_arg.module,
      pending_events: [],
      presence_state: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_channel, topic, opts}, {client_pid, _ref}, state) do
    topic = normalize_topic(topic)

    if channel = find_channel_by_topic(state.channels, topic) do
      {:reply, {:ok, channel}, state}
    else
      channel = Channel.new(topic, client_pid, opts)
      updated_channels = Map.put(state.channels, channel.ref, channel)

      {:reply, {:ok, channel}, %{state | channels: updated_channels}}
    end
  end

  @impl true
  def handle_call({:subscribe, channel, type, filter}, _from, state) do
    if channel = Map.get(state.channels, channel.ref) do
      updated_channel = Channel.add_binding(channel, type, filter)
      updated_channels = Map.put(state.channels, channel.ref, updated_channel)

      {:reply, :ok, %{state | channels: updated_channels}}
    else
      {:reply, {:error, :channel_not_found}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, channel}, _from, state) do
    if channel = Map.get(state.channels, channel.ref) do
      updated_channel = Channel.update_state(channel, :leaving)
      updated_channels = Map.put(state.channels, channel.ref, updated_channel)

      {:reply, :ok, %{state | channels: updated_channels}}
    else
      {:reply, {:error, :channel_not_found}, state}
    end
  end

  @impl true
  def handle_call(:remove_all_channels, _from, state) do
    updated_channels =
      Map.new(state.channels, fn {ref, channel} ->
        {ref, Channel.update_state(channel, :leaving)}
      end)

    {:reply, :ok, %{state | channels: updated_channels}}
  end

  @impl true
  def handle_cast({:handle_message, %{topic: topic, payload: payload, event: event}}, state) do
    matching_channels =
      state.channels
      |> Map.values()
      |> Enum.filter(fn channel -> channel.topic == topic end)

    case event do
      "phx_reply" -> handle_reply(matching_channels, payload, state)
      _ -> handle_event(matching_channels, event, payload, state)
    end
  end

  @impl true
  def handle_cast({:update_join_ref, channel, join_ref}, state) do
    if channel = Map.get(state.channels, channel.ref) do
      updated_channel = Channel.set_join_ref(channel, join_ref)
      updated_channels = Map.put(state.channels, channel.ref, updated_channel)

      {:noreply, %{state | channels: updated_channels}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_channel_state, channel, new_state}, state) do
    if channel = Map.get(state.channels, channel.ref) do
      updated_channel = Channel.update_state(channel, new_state)
      updated_channels = Map.put(state.channels, channel.ref, updated_channel)

      {:noreply, %{state | channels: updated_channels}}
    else
      {:noreply, state}
    end
  end

  # Private helper functions

  defp normalize_topic(topic) do
    if String.starts_with?(topic, "realtime:") do
      topic
    else
      "realtime:#{topic}"
    end
  end

  defp find_channel_by_topic(channels, topic) do
    channels
    |> Map.values()
    |> Enum.find(fn channel -> channel.topic == topic end)
  end

  defp handle_reply(channels, %{"status" => status}, state) do
    updated_channels =
      Enum.reduce(channels, state.channels, &update_channel_state_from_reply(&1, status, &2))

    {:noreply, %{state | channels: updated_channels}}
  end

  defp update_channel_state_from_reply(channel, "ok", acc) do
    channel
    |> Channel.update_state(:joined)
    |> then(&Map.put(acc, channel.ref, &1))
  end

  defp update_channel_state_from_reply(channel, status, acc) when status in ~w(error timeout) do
    channel
    |> Channel.update_state(:errored)
    |> then(&Map.put(acc, channel.ref, &1))
  end

  defp update_channel_state_from_reply(channel, _, acc) do
    Map.put(acc, channel.ref, channel)
  end

  defp handle_event(channels, event, payload, state) when is_database_event(event) do
    db_event_type = String.downcase(event) |> String.to_atom()

    if channels != [] and function_exported?(state.module, :handle_event, 1) do
      Task.start(fn ->
        # enforce event delivery
        :ok = state.module.handle_event({:postgres_changes, db_event_type, payload})
      end)
    else
      Logger.warning("No handle_event/1 callback defined in #{state.module}")
    end

    {:noreply, state}
  end

  defp handle_event(channels, event, payload, state) do
    if channels != [] and function_exported?(state.module, :handle_event, 1) do
      Task.start(fn ->
        :ok = state.module.handle_event({:broadcast, event, payload})
      end)
    else
      Logger.warning("No handle_event/1 callback defined in #{state.module}")
    end

    {:noreply, state}
  end
end

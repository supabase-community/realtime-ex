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
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Message

  require Logger

  @typedoc """
  Registry state holding all subscription information.
  """
  @type state :: %{
          module: module(),
          pending_events: list(),
          presence_state: map(),
          store: pid() | module()
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
    store = Keyword.fetch!(opts, :store)

    GenServer.start_link(__MODULE__, %{module: module, store: store}, name: name)
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

  # Server callbacks

  @impl true
  def init(init_arg) do
    state = %{
      module: init_arg.module,
      store: init_arg.store,
      pending_events: [],
      presence_state: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:create_channel, topic, opts}, _from, state) do
    topic = normalize_topic(topic)

    case Store.find_by_topic(state.store, topic) do
      {:ok, channel} ->
        {:reply, {:ok, channel}, state}

      {:error, :not_found} ->
        channel = Channel.new(topic, self(), opts)
        {:ok, _} = Store.insert(state.store, channel)
        {:reply, {:ok, channel}, state}
    end
  end

  def handle_call({:subscribe, channel, type, filter}, _from, state) do
    case Store.find_by_ref(state.store, channel.ref) do
      {:ok, found_channel} ->
        {:ok, channel} = Store.add_binding(state.store, found_channel, type, filter)
        {:reply, :ok, state, {:continue, {:join, channel}}}

      {:error, :not_found} ->
        {:reply, {:error, :channel_not_found}, state}
    end
  end

  def handle_call({:unsubscribe, channel}, _from, state) do
    case Store.find_by_ref(state.store, channel.ref) do
      {:ok, found_channel} ->
        {:ok, channel} = Store.update_state(state.store, found_channel, :leaving)
        {:reply, :ok, state, {:continue, {:leave, channel}}}

      {:error, :not_found} ->
        {:reply, {:error, :channel_not_found}, state}
    end
  end

  def handle_call(:remove_all_channels, _from, state) do
    for channel <- Store.all(state.store), do: unsubscribe(self(), channel)

    {:reply, :ok, state}
  end

  def handle_call(:get_presence_state, _from, state) do
    {:reply, state.presence_state, state}
  end

  @impl true
  def handle_cast({:handle_message, %{"event" => event, "payload" => payload} = msg}, state) do
    matching_channels = Store.find_all_by_topic(state.store, msg["topic"])

    case event do
      "phx_close" -> handle_leave(msg, state)
      "phx_reply" -> handle_reply(msg, state)
      _ -> handle_event(matching_channels, event, payload, state)
    end
  end

  @impl true
  def handle_continue({:join, channel}, state) do
    if not Channel.joined?(channel) and not Channel.joining?(channel) do
      Logger.debug("[#{channel.topic}] Joining #{channel.ref}")
      {:ok, channel} = Store.update_state(state.store, channel, :joining)
      state.module.send_message(channel, Message.subscription_message(channel))
    end

    {:noreply, state}
  end

  def handle_continue({:leave, channel}, state) do
    Logger.debug("[#{channel.topic}] Leaving #{channel.ref}")
    state.module.send_message(channel, Message.unsubscribe_message(channel))

    {:noreply, state}
  end

  # Private helper functions

  defp normalize_topic(topic) do
    if String.starts_with?(topic, "realtime:") do
      topic
    else
      "realtime:#{topic}"
    end
  end

  defp handle_leave(%{"ref" => join_ref, "topic" => topic} = msg, state) do
    %{"payload" => %{"status" => status}} = msg

    case Store.find_by_join_ref(state.store, join_ref) do
      {:ok, channel} ->
        handle_channel_leaving(channel, status, state)

      {:error, :not_found} ->
        Logger.debug("[#{topic}] Channel not found for leave message with ref #{join_ref}")
    end

    {:noreply, state}
  end

  defp handle_channel_leaving(channel, "ok", state) when channel.state == :leaving do
    Logger.debug("[#{channel.topic}] Successfully left #{channel.ref}")
    Store.remove(state.store, channel)
  end

  defp handle_channel_leaving(channel, "ok", _state) do
    Logger.debug("[#{channel.topic}] Ignoring leave message for #{channel.ref} with status ok")
  end

  defp handle_channel_leaving(channel, status, state) when status in ~w(error timeout) do
    Logger.error("[#{channel.topic}] Failed to leave channel #{channel.ref}: #{status}")
    Store.update_state(state.store, channel, :errored)
  end

  defp handle_channel_leaving(channel, status, _state) do
    Logger.debug("[#{channel.topic}] Ignoring leave message for #{channel.ref} with status #{status}")
  end

  defp handle_reply(%{"ref" => join_ref} = msg, state) do
    %{"payload" => %{"status" => status}} = msg

    case Store.find_by_join_ref(state.store, join_ref) do
      {:ok, channel} ->
        handle_channel_reply(channel, status, state)

      {:error, :not_found} ->
        Logger.debug("Channel not found for reply message with ref #{join_ref}")
    end

    {:noreply, state}
  end

  defp handle_channel_reply(channel, "ok", state) do
    Logger.debug("[#{channel.topic}] Successfully joined #{channel.ref}")
    Store.update_state(state.store, channel, :joined)
  end

  defp handle_channel_reply(channel, status, state) when status in ~w(error timeout) do
    Logger.error("[#{channel.topic}] Failed to join channel #{channel.ref}: #{status}")
    Store.update_state(state.store, channel, :errored)
  end

  defp handle_channel_reply(channel, status, _state) do
    Logger.debug("[#{channel.topic}] Ignoring reply message for #{channel.ref} with status #{status}")
  end

  defp handle_event(channels, event, payload, state) when is_database_event(event) do
    db_event_type = event |> String.downcase() |> String.to_atom()
    dispatch_event(state, channels, {:postgres_changes, db_event_type, payload})
    {:noreply, state}
  end

  defp handle_event(channels, "presence_state", payload, state) do
    new_state = %{state | presence_state: Map.get(payload, "state", %{})}
    dispatch_event(new_state, channels, {:presence, :sync, new_state.presence_state})
    {:noreply, new_state}
  end

  defp handle_event(channels, "presence_diff", payload, state) do
    joins = Map.get(payload, "joins", %{})
    leaves = Map.get(payload, "leaves", %{})

    # Update presence state
    new_state =
      state
      |> add_presence_joins(joins)
      |> remove_presence_leaves(leaves)

    # Dispatch joins/leaves events if present
    if map_size(joins) != 0,
      do: dispatch_event(new_state, channels, {:presence, :join, joins})

    if map_size(leaves) != 0,
      do: dispatch_event(new_state, channels, {:presence, :leave, leaves})

    # Always dispatch the sync event with updated state
    dispatch_event(new_state, channels, {:presence, :sync, new_state.presence_state})

    {:noreply, new_state}
  end

  defp handle_event(channels, _event, %{"type" => "presence", "event" => presence_event, "payload" => payload}, state) do
    # Handle presence events from message payload
    presence_type = String.to_atom(presence_event)
    dispatch_event(state, channels, {:presence, presence_type, payload})
    {:noreply, state}
  end

  defp handle_event(channels, event, payload, state) do
    # Default to broadcast handling
    dispatch_event(state, channels, {:broadcast, event, payload})
    {:noreply, state}
  end

  # Helper to dispatch events to the callback module if available
  defp dispatch_event(state, channels, event) do
    if channels != [] and function_exported?(state.module, :handle_event, 1) do
      Task.start(fn ->
        :ok = state.module.handle_event(event)
      end)
    else
      Logger.warning("No handle_event/1 callback defined in #{state.module}")
    end
  end

  # Helper to add presences (joins)
  defp add_presence_joins(state, joins) do
    presences =
      Enum.reduce(joins, state.presence_state, fn {key, presence}, acc ->
        Map.put(acc, key, presence)
      end)

    %{state | presence_state: presences}
  end

  # Helper to remove presences (leaves)
  defp remove_presence_leaves(state, leaves) do
    presences =
      leaves
      |> Map.keys()
      |> Enum.reduce(state.presence_state, fn key, acc ->
        Map.delete(acc, key)
      end)

    %{state | presence_state: presences}
  end
end

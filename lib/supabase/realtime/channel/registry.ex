defmodule Supabase.Realtime.Channel.Registry do
  @moduledoc """
  Registry for managing Realtime channel subscriptions.

  Tracks active channels and their subscriptions, and routes incoming messages
  to the appropriate callback functions.

  ## Message Routing

  When a message arrives, the registry matches it against channel bindings:

  * **Broadcast events** are matched by event name. Bindings with `event: "*"`
    (wildcard) match every broadcast event on the channel.
  * **Postgres changes** are matched by server-assigned binding IDs. After a
    channel joins, the server reply includes IDs for each postgres_changes
    binding. The registry stores these IDs so that incoming database events
    are dispatched only to the correct bindings.
  * **Presence events** are dispatched to all channels subscribed to the topic.

  ## Connection State Notifications

  When the WebSocket connection state changes (for example, from `:open` to
  `:closed`), the connection process notifies the registry. The registry then
  dispatches a `{:connection, :state_change, %{old: old, new: new}}` event
  to all registered callback modules.

  ## Postgres Type Transforms

  Database change payloads include column metadata. The registry uses
  `Supabase.Realtime.PostgresTypes` to convert string values in `record`
  and `old_record` maps to native Elixir types before dispatching events.
  """

  use GenServer

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection
  alias Supabase.Realtime.PostgresTypes
  alias Supabase.Realtime.Presence

  require Logger

  @typedoc """
  Registry state holding all subscription information.
  """
  @type state :: %{
          module: module(),
          pending_events: list(),
          presence_state: map(),
          store: pid() | module(),
          connection: pid() | module() | nil
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
    connection = opts[:connection]

    GenServer.start_link(__MODULE__, %{module: module, store: store, connection: connection}, name: name)
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
  Lists all active channels.

  ## Parameters

  * `server` - The server PID or name
  """
  @spec list_channels(GenServer.server()) :: [Channel.t()]
  def list_channels(server) do
    GenServer.call(server, :list_channels)
  end

  @doc """
  Subscribes to events on a channel.

  Returns `{:error, :already_joining}` / `{:error, :already_joined}` when a
  `postgres_changes` or `presence` binding is added while the channel is
  joining or joined (realtime-js semantics: these bindings are part of the
  join payload, so they cannot be added after the join started). Broadcast
  bindings are allowed at any time.

  For `postgres_changes` bindings, the `:filter` value may be a
  `%Supabase.Realtime.Filter{}` struct (serialized here) and the `:select`
  option must be a non-empty list of column names, else the call returns
  `{:error, :invalid_select}`.

  ## Parameters

  * `server` - The server PID or name
  * `channel` - The channel struct
  * `type` - The event type
  * `filter` - The event filter
  """
  @spec subscribe(GenServer.server(), Channel.t(), String.t(), map() | keyword()) ::
          :ok | {:error, :channel_not_found | :already_joined | :already_joining | :invalid_select}
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
      connection: init_arg[:connection],
      pending_events: [],
      presence_state: %{}
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:list_channels, _from, state) do
    channels = Store.all(state.store)
    {:reply, channels, state}
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
      # JS 2.101.0 behavior: adding these bindings after subscribe started is a
      # hard error, not a silent drop
      {:ok, found} when found.state in [:joining, :joined] and type in ["postgres_changes", "presence"] ->
        error = if found.state == :joined, do: :already_joined, else: :already_joining
        {:reply, {:error, error}, state}

      {:ok, found} ->
        # normalize before store: an invalid filter is replied as an error
        # without being stored
        case Channel.normalize_filter(type, filter) do
          {:ok, filter} ->
            {:ok, updated} = Store.add_binding(state.store, found, type, filter)

            if updated.state in [:closed, :errored] do
              {:reply, :ok, state, {:continue, {:join, updated}}}
            else
              # broadcast bindings on a joining/joined channel
              {:reply, :ok, state}
            end

          {:error, :invalid_select} ->
            {:reply, {:error, :invalid_select}, state}
        end

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
  def handle_cast({:connection_state_changed, old, new}, state) do
    channels = Store.all(state.store)
    dispatch_event(state, channels, {:connection, :state_change, %{old: old, new: new}})

    if new == :open do
      rejoin_channels(state)
    end

    {:noreply, state}
  end

  def handle_cast({:handle_message, %{"event" => event} = msg}, state) do
    dispatch_message(event, msg, state)
  end

  @impl true
  def handle_continue({:join, channel}, state) do
    if channel.state in [:closed, :errored] do
      {:ok, channel} = Store.update_state(state.store, channel, :joining)

      if state.connection do
        Connection.join_channel(state.connection, channel)
      else
        Logger.debug("no connection; join deferred until :open sweep")
      end
    end

    {:noreply, state}
  end

  def handle_continue({:leave, channel}, state) do
    result =
      if state.connection do
        Connection.leave_channel(state.connection, channel)
      else
        {:error, :not_connected}
      end

    case result do
      # the server lost every channel on disconnect, so the leave is complete
      # locally; on :ok the stored leave_ref waits for the phx_reply / phx_close
      {:error, :not_connected} -> Store.remove(state.store, channel)
      :ok -> :ok
    end

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

  # Rejoin sweep on :open: every channel that was joining, joined or errored
  # gets a fresh join (fresh join_ref, fresh token); leaves that were in
  # flight when the connection died are complete locally.
  defp rejoin_channels(state) do
    if state.connection do
      for channel <- Store.all(state.store), channel.state in [:joining, :joined, :errored] do
        {:ok, ch} = Store.update_state(state.store, channel, :joining)
        Connection.join_channel(state.connection, ch)
      end
    end

    for channel <- Store.all(state.store), channel.state == :leaving do
      Store.remove(state.store, channel)
    end
  end

  defp handle_phx_close(topic, state) do
    # the wire payload is empty (%{}); remove the channel by topic
    case Store.find_by_topic(state.store, topic) do
      {:ok, channel} ->
        Logger.debug("[#{topic}] Channel closed by server")
        Store.remove(state.store, channel)

      {:error, :not_found} ->
        Logger.debug("[#{topic}] Channel not found for close message")
    end

    {:noreply, state}
  end

  defp handle_phx_error(topic, state) do
    case Store.find_by_topic(state.store, topic) do
      {:ok, channel} ->
        Logger.error("[#{topic}] Server sent phx_error, marking channel errored")
        Store.update_state(state.store, channel, :errored)

      {:error, :not_found} ->
        Logger.debug("[#{topic}] Channel not found for error message")
    end

    {:noreply, state}
  end

  defp handle_reply(%{"ref" => ref} = msg, state) do
    status = get_in(msg, ["payload", "status"])
    payload = get_in(msg, ["payload"]) || %{}

    case find_reply_target(state.store, ref) do
      {:join, channel} -> handle_join_reply(channel, status, payload, state)
      {:leave, channel} -> handle_leave_reply(channel, status, state)
      :ignore -> Logger.debug("[#{__MODULE__}]: Ignoring phx_reply for unknown ref: #{inspect(ref)}")
    end

    {:noreply, state}
  end

  defp find_reply_target(store, ref) do
    case Store.find_by_join_ref(store, ref) do
      {:ok, channel} ->
        {:join, channel}

      {:error, _} ->
        case Store.find_by_leave_ref(store, ref) do
          {:ok, channel} -> {:leave, channel}
          {:error, _} -> :ignore
        end
    end
  end

  defp handle_join_reply(channel, "ok", payload, state) do
    Logger.debug("[#{channel.topic}] Successfully joined #{channel.ref}")
    {:ok, joined} = Store.update_state(state.store, channel, :joined)
    maybe_update_binding_ids(joined, payload, state)

    if state.connection do
      GenServer.cast(state.connection, {:channel_joined, channel.topic})
    end
  end

  defp handle_join_reply(channel, status, payload, state) when status in ~w(error timeout) do
    reason = get_in(payload, ["response", "reason"])
    Logger.error("[#{channel.topic}] Failed to join channel #{channel.ref}: #{status} #{reason}")
    Store.update_state(state.store, channel, :errored)
  end

  defp handle_join_reply(channel, status, _payload, _state) do
    Logger.debug("[#{channel.topic}] Ignoring join reply with status #{inspect(status)}")
  end

  defp handle_leave_reply(channel, "ok", state) do
    Logger.debug("[#{channel.topic}] Successfully left #{channel.ref}")
    Store.remove(state.store, channel)
  end

  defp handle_leave_reply(channel, status, state) when status in ~w(error timeout) do
    Logger.error("[#{channel.topic}] Failed to leave channel #{channel.ref}: #{status}")
    Store.update_state(state.store, channel, :errored)
  end

  defp handle_leave_reply(channel, status, _state) do
    Logger.debug("[#{channel.topic}] Ignoring leave reply with status #{inspect(status)}")
  end

  defp handle_postgres_changes(channels, payload, state) do
    ids = Map.get(payload, "ids", [])
    data = Map.get(payload, "data", %{})

    matching =
      Enum.filter(channels, fn channel ->
        channel.bindings
        |> Map.get("postgres_changes", [])
        |> Enum.any?(&(&1.id in ids))
      end)

    case postgres_op(data["type"]) do
      nil ->
        Logger.error("[#{__MODULE__}]: Ignoring postgres_changes with unknown type: #{inspect(data["type"])}")
        {:noreply, state}

      op ->
        dispatch_event(state, matching, {:postgres_changes, op, transform_db_payload(data)})
        {:noreply, state}
    end
  end

  defp postgres_op(type) when is_binary(type) do
    case String.downcase(type) do
      "*" -> :all
      "insert" -> :insert
      "update" -> :update
      "delete" -> :delete
      _other -> nil
    end
  end

  defp postgres_op(_type), do: nil

  defp handle_broadcast(channels, payload, state) do
    name = Map.get(payload, "event")
    user_payload = Map.get(payload, "payload", %{})

    matching =
      if is_binary(name) do
        Enum.filter(channels, fn channel ->
          channel.bindings
          |> Map.get("broadcast", [])
          |> Enum.any?(&broadcast_binding_matches?(&1, name))
        end)
      else
        []
      end

    dispatch_event(state, matching, {:broadcast, name, user_payload})
    {:noreply, state}
  end

  defp broadcast_binding_matches?(%{filter: filter}, name) do
    filter_event = Map.get(filter, :event) || Map.get(filter, "event")

    filter_event == "*" or
      String.downcase(to_string(filter_event)) == String.downcase(name)
  end

  defp handle_presence_state(channels, payload, state) do
    # bug 20: the server sends the state map DIRECTLY as the payload
    new_state = %{state | presence_state: payload}
    dispatch_event(new_state, channels, {:presence, :sync, payload})
    {:noreply, new_state}
  end

  defp handle_presence_diff(channels, payload, state) do
    joins = Map.get(payload, "joins", %{})
    leaves = Map.get(payload, "leaves", %{})

    # bug 21: per-phx_ref merge instead of per-key clobber
    new_state = %{state | presence_state: Presence.sync_diff(state.presence_state, payload)}

    # Dispatch joins/leaves events if present
    if map_size(joins) != 0,
      do: dispatch_event(new_state, channels, {:presence, :join, joins})

    if map_size(leaves) != 0,
      do: dispatch_event(new_state, channels, {:presence, :leave, leaves})

    # Always dispatch the sync event with updated state
    dispatch_event(new_state, channels, {:presence, :sync, new_state.presence_state})

    {:noreply, new_state}
  end

  defp transform_db_payload(payload) do
    columns = Map.get(payload, "columns", [])

    payload
    |> maybe_transform("record", columns)
    |> maybe_transform("old_record", columns)
  end

  defp maybe_transform(payload, key, columns) do
    case Map.get(payload, key) do
      nil -> payload
      record -> Map.put(payload, key, PostgresTypes.transform(record, columns))
    end
  end

  defp maybe_update_binding_ids(channel, %{"response" => %{"postgres_changes" => server_bindings}}, state)
       when is_list(server_bindings) do
    client_bindings = Map.get(channel.bindings, "postgres_changes", [])
    client_bindings_reversed = Enum.reverse(client_bindings)

    updated_bindings =
      client_bindings_reversed
      |> Enum.with_index()
      |> Enum.map(fn {binding, idx} ->
        case Enum.at(server_bindings, idx) do
          %{"id" => id} -> %{binding | id: id}
          _ -> binding
        end
      end)
      |> Enum.reverse()

    updated_channel = %{channel | bindings: Map.put(channel.bindings, "postgres_changes", updated_bindings)}
    Store.update(state.store, updated_channel)
  end

  defp maybe_update_binding_ids(_channel, _payload, _state), do: :ok

  # Wire-event dispatch. One function head per event keeps each clause's
  # cyclomatic complexity flat as the event table grows.
  defp dispatch_message("phx_close", msg, state), do: handle_phx_close(msg_topic(msg), state)

  defp dispatch_message("phx_error", msg, state), do: handle_phx_error(msg_topic(msg), state)

  defp dispatch_message("phx_reply", msg, state), do: handle_reply(msg, state)

  defp dispatch_message("postgres_changes", msg, state),
    do: handle_postgres_changes(topic_channels(msg, state), msg_payload(msg), state)

  defp dispatch_message("broadcast", msg, state),
    do: handle_broadcast(topic_channels(msg, state), msg_payload(msg), state)

  defp dispatch_message("presence_state", msg, state),
    do: handle_presence_state(topic_channels(msg, state), msg_payload(msg), state)

  defp dispatch_message("presence_diff", msg, state),
    do: handle_presence_diff(topic_channels(msg, state), msg_payload(msg), state)

  defp dispatch_message("system", msg, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring system message: #{inspect(msg_payload(msg))}")
    {:noreply, state}
  end

  defp dispatch_message(event, _msg, state) do
    Logger.debug("[#{__MODULE__}]: Ignoring unknown event: #{inspect(event)}")
    {:noreply, state}
  end

  defp msg_topic(msg), do: Map.get(msg, "topic")
  defp msg_payload(msg), do: Map.get(msg, "payload", %{})
  defp topic_channels(msg, state), do: Store.find_all_by_topic(state.store, msg_topic(msg))

  # Helper to dispatch events to the callback module if available. Zero
  # matching channels is a normal no-op, not a missing callback; the warning
  # stays for the genuinely-missing-callback case with channels present.
  defp dispatch_event(_state, [], _event), do: :ok

  defp dispatch_event(state, _channels, event) do
    if function_exported?(state.module, :handle_event, 1) do
      Task.start(fn ->
        :ok = state.module.handle_event(event)
      end)
    else
      Logger.warning("No handle_event/1 callback defined in #{state.module}")
    end
  end
end

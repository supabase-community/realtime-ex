defmodule Supabase.Realtime.Channel.Store do
  @moduledoc """
  ETS-based storage for Realtime channels.

  This module provides a centralized store for channel data that can be
  accessed by both the Connection and Registry modules, eliminating the
  need for manual state management in each component.
  """

  use GenServer

  alias Supabase.Realtime.Channel

  require Logger

  @table_name :supabase_realtime_channels

  # Client API

  @doc """
  Starts the channel store.

  ## Options

  * `:name` - Optional registration name
  """
  def start_link(opts \\ []) do
    name = opts[:name] || __MODULE__
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Inserts a new channel into the store.

  ## Parameters

  * `store` - The store process
  * `channel` - The channel to insert
  """
  def insert(store \\ __MODULE__, %Channel{} = channel) do
    GenServer.call(store, {:insert, channel})
  end

  @doc """
  Updates an existing channel in the store.

  ## Parameters

  * `store` - The store process
  * `channel` - The updated channel data
  """
  def update(store \\ __MODULE__, %Channel{} = channel) do
    GenServer.call(store, {:update, channel})
  end

  @doc """
  Updates the state of a channel.

  ## Parameters

  * `store` - The store process
  * `channel` - The channel to update
  * `state` - The new channel state
  """
  def update_state(store \\ __MODULE__, %Channel{} = channel, state) do
    GenServer.call(store, {:update_state, channel, state})
  end

  @doc """
  Updates the join reference of a channel.

  ## Parameters

  * `store` - The store process
  * `channel` - The channel to update
  * `join_ref` - The new join reference
  """
  def update_join_ref(store \\ __MODULE__, %Channel{} = channel, join_ref) do
    GenServer.call(store, {:update_join_ref, channel, join_ref})
  end

  @doc """
  Adds a binding to a channel.

  ## Parameters

  * `store` - The store process
  * `channel` - The channel to update
  * `type` - The binding type
  * `filter` - The binding filter
  * `callback` - Optional callback function
  """
  def add_binding(store \\ __MODULE__, %Channel{} = channel, type, filter, callback \\ nil) do
    GenServer.call(store, {:add_binding, channel, type, filter, callback})
  end

  @doc """
  Removes a binding from a channel.

  ## Parameters

  * `store` - The store process
  * `channel` - The channel to update
  * `type` - The binding type
  * `filter` - The binding filter
  """
  def remove_binding(store \\ __MODULE__, %Channel{} = channel, type, filter) do
    GenServer.call(store, {:remove_binding, channel, type, filter})
  end

  @doc """
  Removes a channel from the store.

  ## Parameters

  * `store` - The store process
  * `channel` - The channel to remove
  """
  def remove(store \\ __MODULE__, %Channel{} = channel) do
    GenServer.call(store, {:remove, channel})
  end

  @doc """
  Finds a channel by its reference.

  ## Parameters

  * `store` - The store process
  * `ref` - The channel reference
  """
  def find_by_ref(store \\ __MODULE__, ref) when is_binary(ref) do
    GenServer.call(store, {:find_by_ref, ref})
  end

  @doc """
  Finds a channel by its topic.

  ## Parameters

  * `store` - The store process
  * `topic` - The channel topic
  """
  def find_by_topic(store \\ __MODULE__, topic) when is_binary(topic) do
    GenServer.call(store, {:find_by_topic, topic})
  end

  @doc """
  Finds a channel by its join reference.

  ## Parameters

  * `store` - The store process
  * `join_ref` - The join reference
  """
  def find_by_join_ref(store \\ __MODULE__, join_ref) when is_binary(join_ref) do
    GenServer.call(store, {:find_by_join_ref, join_ref})
  end

  @doc """
  Returns all channels in the store.

  ## Parameters

  * `store` - The store process
  """
  def all(store \\ __MODULE__) do
    GenServer.call(store, :all)
  end

  @doc """
  Finds all channels with a matching topic.

  ## Parameters

  * `store` - The store process
  * `topic` - The topic to match
  """
  def find_all_by_topic(store \\ __MODULE__, topic) when is_binary(topic) do
    GenServer.call(store, {:find_all_by_topic, topic})
  end

  # Server callbacks

  @impl true
  def init(opts) do
    table_name = Keyword.get(opts, :table_name, @table_name)
    table = :ets.new(table_name, [:set, :protected, :named_table])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:insert, %Channel{} = channel}, _from, state) do
    # Primary key: channel ref
    # Secondary indices: topic, join_ref
    :ets.insert(state.table, {channel.ref, channel, channel.topic, channel.join_ref})

    {:reply, {:ok, channel}, state}
  end

  @impl true
  def handle_call({:update, %Channel{} = channel}, _from, state) do
    :ets.insert(state.table, {channel.ref, channel, channel.topic, channel.join_ref})

    {:reply, {:ok, channel}, state}
  end

  @impl true
  def handle_call({:update_state, %Channel{} = channel, new_state}, _from, state) do
    updated_channel = Channel.update_state(channel, new_state)
    :ets.insert(state.table, {channel.ref, updated_channel, channel.topic, channel.join_ref})

    {:reply, {:ok, updated_channel}, state}
  end

  @impl true
  def handle_call({:update_join_ref, %Channel{} = channel, join_ref}, _from, state) do
    updated_channel = Channel.set_join_ref(channel, join_ref)
    :ets.insert(state.table, {channel.ref, updated_channel, channel.topic, join_ref})

    {:reply, {:ok, updated_channel}, state}
  end

  @impl true
  def handle_call({:add_binding, %Channel{} = channel, type, filter, callback}, _from, state) do
    updated_channel = Channel.add_binding(channel, type, filter, callback)
    :ets.insert(state.table, {channel.ref, updated_channel, channel.topic, channel.join_ref})

    {:reply, {:ok, updated_channel}, state}
  end

  @impl true
  def handle_call({:remove_binding, %Channel{} = channel, type, filter}, _from, state) do
    updated_channel = Channel.remove_binding(channel, type, filter)
    :ets.insert(state.table, {channel.ref, updated_channel, channel.topic, channel.join_ref})

    {:reply, {:ok, updated_channel}, state}
  end

  @impl true
  def handle_call({:remove, %Channel{} = channel}, _from, state) do
    :ets.delete(state.table, channel.ref)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:find_by_ref, ref}, _from, state) do
    {:reply,
     case :ets.lookup(state.table, ref) do
       [{^ref, channel, _, _}] -> {:ok, channel}
       [] -> {:error, :not_found}
     end, state}
  end

  @impl true
  def handle_call({:find_by_topic, topic}, _from, state) do
    result = :ets.select(state.table, [{{:_, :"$1", topic, :_}, [], [:"$1"]}])

    {:reply,
     case result do
       [channel | _] -> {:ok, channel}
       [] -> {:error, :not_found}
     end, state}
  end

  @impl true
  def handle_call({:find_by_join_ref, join_ref}, _from, state) do
    result = :ets.select(state.table, [{{:_, :"$1", :_, join_ref}, [], [:"$1"]}])

    {:reply,
     case result do
       [channel | _] -> {:ok, channel}
       [] -> {:error, :not_found}
     end, state}
  end

  @impl true
  def handle_call(:all, _from, state) do
    channels = :ets.select(state.table, [{{:_, :"$1", :_, :_}, [], [:"$1"]}])
    {:reply, channels, state}
  end

  @impl true
  def handle_call({:find_all_by_topic, topic}, _from, state) do
    channels = :ets.select(state.table, [{{:_, :"$1", topic, :_}, [], [:"$1"]}])
    {:reply, channels, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.table && :ets.info(state.table) != :undefined do
      :ets.delete(state.table)
    end

    :ok
  end
end

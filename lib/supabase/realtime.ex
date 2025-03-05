defmodule Supabase.Realtime do
  @moduledoc """
  Client for interacting with Supabase Realtime service.

  This module provides a behavior for implementing Realtime clients that connect
  to Supabase's Realtime service. It enables applications to subscribe to
  database changes, broadcast messages, and maintain presence information.

  ## Usage

  Define a module that uses `Supabase.Realtime`:

      defmodule MyApp.Realtime do
        use Supabase.Realtime

        def start_link(opts \\ []) do
          Supabase.Realtime.start_link(__MODULE__, opts)
        end

        @impl true
        def handle_event({:postgres_changes, :insert, payload}) do
          # Handle INSERT events
        end

        @impl true
        def handle_event({:postgres_changes, :update, payload}) do
          # Handle UPDATE events
        end
      end

  Add it to your supervision tree:

      children = [
        {MyApp.Supabase, []},
        {MyApp.Realtime, supabase_client: MyApp.Supabase}
      ]

  Subscribe to database changes:

      channel = MyApp.Realtime.channel("public:users")
      MyApp.Realtime.on(channel, "postgres_changes",
        event: :insert,
        schema: "public",
        table: "users"
      )
  """

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel

  @typedoc """
  Connection states for the WebSocket client.

  * `:connecting` - Attempting to establish connection
  * `:open` - Connection is established and operational
  * `:closing` - Connection is in the process of closing
  * `:closed` - Connection is closed
  """
  @type connection_state :: :connecting | :open | :closing | :closed

  @typedoc """
  Channel states for subscriptions.

  * `:closed` - Channel is not subscribed
  * `:errored` - Channel encountered an error during subscription
  * `:joined` - Channel is successfully subscribed
  * `:joining` - Channel is in the process of subscribing
  * `:leaving` - Channel is in the process of unsubscribing
  """
  @type channel_state :: :closed | :errored | :joined | :joining | :leaving

  @typedoc """
  Subscription states for channels.

  * `:subscribed` - Successfully subscribed to events
  * `:timed_out` - Subscription attempt timed out
  * `:closed` - Subscription has been closed
  * `:channel_error` - Error occurred during subscription
  """
  @type subscribe_state :: :subscribed | :timed_out | :closed | :channel_error

  @typedoc """
  Types of events that can be received from the server.

  * `:broadcast` - User-generated broadcast messages
  * `:presence` - Presence state updates
  * `:postgres_changes` - Database change events
  * `:system` - System events like heartbeats
  """
  @type realtime_listen_type :: :broadcast | :presence | :postgres_changes | :system

  @type client :: module() | atom()
  @type t :: pid() | atom()
  @type channel :: Channel.t()
  @type event_type :: :postgres_changes | :broadcast | :presence
  @type event_filter :: Enumerable.t()
  @type channel_opts :: keyword()
  @type start_option :: {:name, atom()} | {:supabase_client, client()} | {:timeout, pos_integer()}
  @typedoc """
  Types of PostgreSQL database changes.

  * `:all` - All event types (represented as `*` in filters)
  * `:insert` - Record insertion
  * `:update` - Record update
  * `:delete` - Record deletion
  """
  @type postgres_changes_event_type :: :all | :insert | :update | :delete
  @typedoc """
  Filter for PostgreSQL database changes.
  """
  @type postgres_changes_filter :: %{
          required(:event) => postgres_changes_event_type() | String.t(),
          required(:schema) => String.t(),
          optional(:table) => String.t(),
          optional(:filter) => String.t()
        }
  @typedoc """
  Types of PostgreSQL database changes.

  * `:all` - All event types (represented as `*` in filters)
  * `:insert` - Record insertion
  * `:update` - Record update
  * `:delete` - Record deletion
  """
  @type postgres_change_event ::
          {:postgres_changes, postgres_changes_event_type(), postgres_changes_filter()}
  @type broadcast_event ::
          {:broadcast, String.t(), map()}
  @typedoc """
  Types of presence events.

  * `:join` - User has joined
  * `:leave` - User has left
  * `:sync` - Presence state synchronization
  """
  @type presence_event ::
          {:presence, :join | :leave | :sync, map()}

  @typedoc """
  Represents a channel subscription event.
  """
  @type event :: postgres_change_event() | broadcast_event() | presence_event()

  @typedoc """
  Message reference type used for tracking message delivery.
  """
  @type ref :: String.t()

  @typedoc """
  Realtime message payload structure.
  """
  @type realtime_message :: %{
          topic: String.t(),
          event: String.t(),
          payload: map(),
          ref: ref(),
          join_ref: ref() | nil
        }

  @typedoc """
  Configuration options for realtime connection.
  """
  @type config_options :: %{
          optional(:broadcast) => %{
            optional(:self) => boolean(),
            optional(:ack) => boolean()
          },
          optional(:presence) => %{
            optional(:key) => String.t()
          },
          optional(:postgres_changes) => list(postgres_changes_filter()),
          optional(:private) => boolean()
        }

  @typedoc """
  Error response for various operations.
  """
  @type error_response ::
          {:error, :subscription_error, String.t()}
          | {:error, :connection_error, String.t()}
          | {:error, :invalid_channel, String.t()}
          | {:error, :timeout, String.t()}
          | {:error, atom(), String.t()}

  @doc """
  Callback invoked when a realtime event is received.

  This callback is called whenever an event matching the subscribed patterns
  is received from the server.

  ## Parameters

  * `event` - The event data structured based on its type:
    * `{:postgres_changes, operation, payload}` - Database change events
    * `{:broadcast, event_name, payload}` - Broadcast messages
    * `{:presence, presence_event, payload}` - Presence updates
  """
  @callback handle_event(event()) :: :ok

  defmacro __using__(_opts) do
    quote do
      use Supervisor

      @behaviour Supabase.Realtime

      @impl Supervisor
      def init(opts) do
        module = opts[:name] || __MODULE__
        client = Keyword.fetch!(opts, :supabase_client)
        heartbeat_interval = opts[:heartbeat_interval] || :timer.seconds(30)
        store_name = Module.concat(module, Store)
        registry_name = Module.concat(module, Registry)
        conn_name = Module.concat(module, Connection)
        reconnect_after_ms = opts[:reconnect_after_ms]

        children =
          [
            {Channel.Store, name: store_name},
            {Channel.Registry, module: module, name: registry_name},
            {Realtime.Connection,
             name: conn_name,
             registry: registry_name,
             client: client,
             heartbeat_interval: heartbeat_interval,
             reconnect_after_ms: reconnect_after_ms}
          ]

        Supervisor.init(children, strategy: :one_for_one)
      end

      @doc """
      Check `Supabase.Realtime.channel/3` for more information.
      """
      def channel(topic, opts \\ []) do
        with {:ok, registry} <- Realtime.fetch_channel_registry(__MODULE__) do
          Realtime.channel(registry, topic, opts)
        end
      end

      @doc """
      Check `Supabase.Realtime.remove_all_channels/1` for more information.
      """
      def remove_all_channels do
        with {:ok, registry} <- Realtime.fetch_channel_registry(__MODULE__) do
          Realtime.remove_all_channels(registry)
        end
      end

      @doc """
      Check `Supabase.Realtime.connection_state/1` for more information.
      """
      def connection_state do
        with {:ok, conn} <- Realtime.fetch_connection(__MODULE__) do
          Realtime.connection_state(conn)
        end
      end

      @doc """
      Check `Supabase.Realtime.on/3` for more information.
      """
      defdelegate on(channel, type, filter), to: Realtime

      @doc """
      Check `Supabase.Realtime.send/2` for more information.
      """
      def send(channel, payload) do
        with {:ok, conn} <- Realtime.fetch_connection(__MODULE__) do
          Realtime.send(conn, channel, payload)
        end
      end

      @doc """
      Check `Supabase.Realtime.unsubscribe/1` for more information.
      """
      defdelegate unsubscribe(channel), to: Realtime
    end
  end

  @doc """
  Starts a Realtime client process linked to the current process.

  ## Options

  * `:name` - Registers the process with the given name
  * `:supabase_client` - The Supabase client to use for configuration
  * `:timeout` - Connection timeout in milliseconds (default: 10000)
  * `:heartbeat_interval` - Interval in milliseconds between heartbeats (default: 30s)
  * `:reconnect_after_ms` - Function that returns reconnection delay based on attempts
  """
  @spec start_link(module(), [start_option()]) :: Supervisor.on_start()
  def start_link(module, opts \\ []) do
    Supervisor.start_link(module, opts, name: module)
  end

  @doc """
  Creates a new channel for subscription.

  ## Parameters

  * `client` - The client module or PID
  * `topic` - The topic to subscribe to
  * `opts` - Channel options

  ## Returns

  * `{:ok, channel}` - A channel struct
  """
  @spec channel(client() | t(), String.t(), channel_opts()) :: {:ok, channel()} | {:error, term()}
  def channel(client, topic, opts \\ []) do
    with pid when is_pid(pid) <- ensure_pid(client) do
      Channel.Registry.create_channel(pid, topic, opts)
    end
  end

  @doc """
  Subscribes to events on a channel with an event filter.

  ## Parameters

  * `channel` - The channel struct returned by `channel/3`
  * `type` - The event type (e.g., "postgres_changes", "broadcast", "presence")
  * `filter` - Filter options like event type, schema, table, etc.

  ## Examples

      Realtime.on(channel, "postgres_changes", event: :insert, schema: "public", table: "users")
      Realtime.on(channel, "broadcast", event: "new_message")
      Realtime.on(channel, "presence", event: "join")
  """
  @spec on(channel(), String.t(), event_filter()) :: :ok | {:error, term()}
  def on(%Channel{} = channel, type, filter)
      when is_binary(type) and (is_list(filter) or is_map(filter)) do
    with pid when is_pid(pid) <- ensure_pid(channel.registry) do
      Channel.Registry.subscribe(pid, channel, type, filter)
    end
  end

  @doc """
  Sends a message on a channel.

  ## Parameters

  * `conn` - The connection PID or name
  * `channel` - The channel struct
  * `payload` - The message payload
  * `opts` - Send options (e.g., timeout)

  ## Examples

      Realtime.send(channel, type: "broadcast", event: "new_message", payload: %{body: "Hello"})
  """
  @spec send(pid | module, channel(), map()) :: :ok | {:error, term()}
  def send(conn, %Channel{} = channel, payload) when is_map(payload) do
    with pid when is_pid(pid) <- ensure_pid(conn) do
      Realtime.Connection.send_message(pid, channel, payload)
    end
  end

  @doc """
  Unsubscribes from a channel.

  ## Parameters

  * `channel` - The channel to unsubscribe from
  """
  @spec unsubscribe(channel()) :: :ok | {:error, term()}
  def unsubscribe(%Channel{} = channel) do
    with pid when is_pid(pid) <- ensure_pid(channel.registry) do
      Channel.Registry.unsubscribe(pid, channel)
    end
  end

  @doc """
  Removes all channel subscriptions.

  ## Parameters

  * `registry` - The channel registry module or PID
  """
  @spec remove_all_channels(client() | t()) :: :ok | {:error, term()}
  def remove_all_channels(registry) do
    with pid when is_pid(pid) <- ensure_pid(registry) do
      Channel.Registry.remove_all_channels(pid)
    end
  end

  @doc """
  Gets the connection status.

  ## Parameters

  * `client` - The client module or PID
  """
  @spec connection_state(client() | t()) :: connection_state()
  def connection_state(client) do
    with pid when is_pid(pid) <- ensure_pid(client) do
      Realtime.Connection.state(pid)
    end
  end

  @doc """
  Fetches the channel registry for a client.

  ## Parameters

  * `realtime` - The client module or PID
  """
  def fetch_channel_registry(realtime) do
    registry_name = Module.concat(realtime, Registry)

    if pid = Process.whereis(registry_name) do
      {:ok, pid}
    else
      {:error, :registry_not_found}
    end
  end

  @doc """
  Fetches the connection PID for a client.

  ## Parameters

  * `realtime` - The client module or PID
  """
  def fetch_connection(realtime) do
    conn_name = Module.concat(realtime, Connection)

    if pid = Process.whereis(conn_name) do
      {:ok, pid}
    else
      {:error, :connection_not_found}
    end
  end

  # Helper function to ensure we have a PID
  defp ensure_pid(client) when is_pid(client), do: client
  defp ensure_pid(client) when is_atom(client), do: Process.whereis(client)
  defp ensure_pid(_), do: {:error, :invalid_client}
end

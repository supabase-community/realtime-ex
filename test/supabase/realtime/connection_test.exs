defmodule Supabase.Realtime.ConnectionTest do
  # Using async: false as we're mocking global modules
  use ExUnit.Case, async: false
  use Mimic
  import ExUnit.CaptureLog

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection

  @moduletag capture_log: true

  # Mock client for tests
  defmodule MockClient do
    def get_client do
      {:ok,
       %Supabase.Client{
         api_key: "mock_api_key",
         realtime_url: "https://example.com",
         base_url: "https://example.com",
         access_token: "mock_token"
       }}
    end
  end

  setup do
    # Set Mimic global for this test module
    set_mimic_global()

    # Unique names for test isolation
    registry_name = :"Registry#{System.unique_integer([:positive])}"
    store_name = :"Store#{System.unique_integer([:positive])}"
    conn_name = :"Connection#{System.unique_integer([:positive])}"

    # Start required processes
    start_supervised!({Store, name: store_name})
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name})

    # Create a channel for testing
    {:ok, channel} = Registry.create_channel(registry_name, "test_topic")

    # Return the context
    {:ok,
     %{
       registry: registry_name,
       store: store_name,
       channel: channel,
       conn_name: conn_name
     }}
  end

  describe "start_link/1" do
    test "starts the connection process", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      # Stub the functions that would be called during connection setup
      # to avoid real connections
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: conn_name,
        registry: registry,
        store: store,
        client: MockClient
      ]

      assert {:ok, _conn_pid} = Connection.start_link(opts)
      assert Process.whereis(conn_name) != nil
    end
  end

  describe "send_message/3" do
    test "returns error when not connected", %{
      registry: registry,
      store: store,
      conn_name: conn_name,
      channel: channel
    } do
      # Stub everything to prevent actual connections
      stub(:gun, :open, fn _, _, _ -> {:error, :not_started} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: conn_name,
        registry: registry,
        store: store,
        client: MockClient
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      # Force to closed state with nil socket
      :sys.replace_state(pid, fn state -> %{state | status: :closed, socket: nil} end)

      # Try to send a message
      payload = %{event: "test_event", payload: %{data: "test"}}
      assert {:error, :not_connected} = Connection.send_message(pid, channel, payload)
    end
  end

  describe "connection state" do
    test "connection state API works", %{registry: registry, store: store, conn_name: conn_name} do
      # Stub all the functions that would be called
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: conn_name,
        registry: registry,
        store: store,
        client: MockClient
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      # Force connection states to test the API
      :sys.replace_state(pid, fn state -> %{state | status: :connecting} end)
      assert Connection.state(pid) == :connecting

      :sys.replace_state(pid, fn state -> %{state | status: :open} end)
      assert Connection.state(pid) == :open

      :sys.replace_state(pid, fn state -> %{state | status: :closed} end)
      assert Connection.state(pid) == :closed
    end
  end

  test "handles errors for failed connection", %{
    registry: registry,
    store: store,
    conn_name: conn_name
  } do
    # Stub gun.open to return an error
    stub(:gun, :open, fn _, _, _ -> {:error, :connection_refused} end)
    stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
    stub(:gun, :ws_send, fn _, _, _ -> :ok end)

    opts = [
      name: conn_name,
      registry: registry,
      store: store,
      client: MockClient,
      # Short delay for testing
      reconnect_after_ms: fn _ -> 500 end
    ]

    # Capture log to verify error handling
    log =
      capture_log(fn ->
        {:ok, _pid} = Connection.start_link(opts)
        Process.sleep(100)
      end)

    assert log =~ "Failed to connect"
  end

  test "connection process initializes properly", %{
    registry: registry,
    store: store,
    conn_name: conn_name
  } do
    # Stub all the functions that would be called
    stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
    stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
    stub(:gun, :ws_send, fn _, _, _ -> :ok end)

    opts = [
      name: conn_name,
      registry: registry,
      store: store,
      client: MockClient
    ]

    {:ok, pid} = Connection.start_link(opts)
    Process.sleep(50)

    # Check that basic state is set
    state = :sys.get_state(pid)
    assert state.registry == registry
    assert state.store == store
    assert state.client == MockClient
    # default
    assert state.heartbeat_interval == 30_000

    # Connection should be attempting to connect
    assert state.status == :connecting
  end
end

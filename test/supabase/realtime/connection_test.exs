defmodule Supabase.Realtime.ConnectionTest do
  # Using async: false as we're mocking global modules
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection

  @moduletag capture_log: true

  @mock_client %Supabase.Client{
    api_key: "mock_api_key",
    realtime_url: "https://example.com",
    base_url: "https://example.com",
    access_token: "mock_token"
  }

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
        client: @mock_client
      ]

      assert {:ok, _conn_pid} = Connection.start_link(opts)
      assert Process.whereis(conn_name)
    end
  end

  describe "send_message/3" do
    test "buffers messages when not connected", %{
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
        client: @mock_client
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      # Force to closed state with nil socket
      :sys.replace_state(pid, fn state -> %{state | status: :closed, socket: nil} end)

      # Messages are buffered instead of returning error
      payload = %{event: "test_event", payload: %{data: "test"}}
      assert :ok = Connection.send_message(pid, channel, payload)

      state = :sys.get_state(pid)
      assert state.send_buffer_size == 1
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
        client: @mock_client
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
      client: @mock_client,
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

  describe "token resolution" do
    defp capture_upgrade_headers(opts) do
      test = self()

      stub(:gun, :open, fn _, _, _ -> {:ok, test} end)

      stub(:gun, :ws_upgrade, fn _socket, _path, headers ->
        send(test, {:upgrade_headers, headers})
        make_ref()
      end)

      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      pid = start_supervised!({Connection, opts})
      send(pid, {:gun_up, test, :http})
      assert_receive {:upgrade_headers, headers}, 1000
      headers
    end

    test "falls back to api_key when client.access_token is nil", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      client = %{@mock_client | access_token: nil}

      headers =
        capture_upgrade_headers(name: conn_name, registry: registry, store: store, client: client)

      auth = List.keyfind(headers, ~c"authorization", 0)
      assert auth == {~c"authorization", ~c"Bearer mock_api_key"}
    end

    test "access_token_fn wins over client token", %{registry: registry, store: store, conn_name: conn_name} do
      headers =
        capture_upgrade_headers(
          name: conn_name,
          registry: registry,
          store: store,
          client: @mock_client,
          access_token_fn: fn -> {:ok, "fn_token"} end
        )

      assert List.keyfind(headers, ~c"authorization", 0) == {~c"authorization", ~c"Bearer fn_token"}
    end

    test "failing access_token_fn falls through to client token", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      headers =
        capture_upgrade_headers(
          name: conn_name,
          registry: registry,
          store: store,
          client: @mock_client,
          access_token_fn: fn -> {:error, :unavailable} end
        )

      assert List.keyfind(headers, ~c"authorization", 0) == {~c"authorization", ~c"Bearer mock_token"}
    end
  end

  describe "gun options" do
    defp capture_open_opts(opts) do
      test = self()

      stub(:gun, :open, fn _host, _port, gun_opts ->
        send(test, {:gun_open_opts, gun_opts})
        {:error, :econnrefused}
      end)

      start_supervised!({Connection, opts})
      assert_receive {:gun_open_opts, gun_opts}, 1000
      gun_opts
    end

    test "uses retry 0 and verify_peer TLS for wss URLs", %{registry: registry, store: store, conn_name: conn_name} do
      client = %{@mock_client | realtime_url: "wss://example.com"}

      opts =
        capture_open_opts(name: conn_name, registry: registry, store: store, client: client)

      assert opts.retry == 0
      assert opts.transport == :tls
      assert Keyword.get(opts.tls_opts, :verify) == :verify_peer
      assert cacerts = Keyword.get(opts.tls_opts, :cacerts)
      assert is_list(cacerts) and cacerts != []
      assert Keyword.get(opts.tls_opts, :server_name_indication) == ~c"example.com"
      assert Keyword.get(opts.tls_opts, :customize_hostname_check)
      refute Keyword.get(opts.tls_opts, :verify) == :verify_none
    end

    test ":tls_opts start option merges over the verify_peer defaults", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      client = %{@mock_client | realtime_url: "wss://example.com"}

      opts =
        capture_open_opts(
          name: conn_name,
          registry: registry,
          store: store,
          client: client,
          tls_opts: [depth: 5]
        )

      assert Keyword.get(opts.tls_opts, :depth) == 5
      assert Keyword.get(opts.tls_opts, :verify) == :verify_peer
      assert Keyword.get(opts.tls_opts, :cacerts) != []
    end

    test "plain ws URLs get no tls_opts", %{registry: registry, store: store, conn_name: conn_name} do
      client = %{@mock_client | realtime_url: "http://example.com"}

      opts =
        capture_open_opts(name: conn_name, registry: registry, store: store, client: client)

      assert opts.transport == :tcp
      refute Map.has_key?(opts, :tls_opts)
    end
  end

  describe "reconnect backoff" do
    test "default backoff steps through the reconnect intervals", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      stub(:gun, :open, fn _, _, _ -> {:error, :econnrefused} end)

      opts = [
        name: conn_name,
        registry: registry,
        store: store,
        client: @mock_client
      ]

      start_supervised!({Connection, opts})
      Process.sleep(50)

      for expected <- [1000, 2000, 5000, 10_000, 10_000] do
        timer = :sys.get_state(conn_name).reconnect_timer
        assert is_reference(timer)
        remaining = Process.cancel_timer(timer)
        assert remaining in (expected - 150)..expected
        send(conn_name, :reconnect)
        Process.sleep(10)
      end
    end

    test "reconnect_attempts resets to 0 when the connection opens", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [name: conn_name, registry: registry, store: store, client: @mock_client]
      start_supervised!({Connection, opts})
      Process.sleep(50)

      socket = self()
      stream_ref = make_ref()

      :sys.replace_state(conn_name, fn state ->
        %{state | reconnect_attempts: 3, socket: socket, stream_ref: stream_ref, status: :connecting}
      end)

      send(conn_name, {:gun_upgrade, socket, stream_ref, ["websocket"], []})
      Process.sleep(50)

      state = :sys.get_state(conn_name)
      assert state.status == :open
      assert state.reconnect_attempts == 0
    end
  end

  describe "connection lifecycle" do
    defp drive_to_open(conn) do
      socket = self()
      stream_ref = make_ref()

      :sys.replace_state(conn, fn state ->
        %{state | socket: socket, stream_ref: stream_ref, status: :connecting}
      end)

      send(conn, {:gun_upgrade, socket, stream_ref, ["websocket"], []})
      Process.sleep(20)
      {socket, stream_ref}
    end

    defp stub_close do
      test = self()

      stub(:gun, :close, fn socket ->
        send(test, {:gun_closed, socket})
        :ok
      end)
    end

    test "keeps exactly one heartbeat timer across upgrades", %{registry: registry, store: store, conn_name: conn_name} do
      test = self()
      stub(:gun, :open, fn _, _, _ -> {:ok, test} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      start_supervised!({Connection, name: conn_name, registry: registry, store: store, client: @mock_client})
      Process.sleep(50)

      {socket, _stream_ref} = drive_to_open(conn_name)

      first_timer = :sys.get_state(conn_name).heartbeat_timer
      assert is_reference(first_timer)
      refute Process.read_timer(first_timer) == false

      # a repeated gun_up and a successful reconnect do not add a second timer
      send(conn_name, {:gun_up, socket, :http})
      Process.sleep(20)
      assert :sys.get_state(conn_name).heartbeat_timer == first_timer

      send(conn_name, :reconnect)
      Process.sleep(20)
      current_ref = :sys.get_state(conn_name).stream_ref
      send(conn_name, {:gun_upgrade, socket, current_ref, ["websocket"], []})
      Process.sleep(20)

      state = :sys.get_state(conn_name)
      assert state.heartbeat_timer != first_timer
      assert Process.read_timer(first_timer) == false
      refute Process.read_timer(state.heartbeat_timer) == false
    end

    test "dead heartbeat forces close and schedules reconnect", %{registry: registry, store: store, conn_name: conn_name} do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)
      stub_close()

      start_supervised!({Connection, name: conn_name, registry: registry, store: store, client: @mock_client})
      Process.sleep(50)
      {socket, _stream_ref} = drive_to_open(conn_name)

      :sys.replace_state(conn_name, fn state -> %{state | pending_heartbeat_ref: "msg:dead"} end)
      send(conn_name, :heartbeat)
      Process.sleep(50)

      assert_received {:gun_closed, ^socket}

      state = :sys.get_state(conn_name)
      assert state.status == :closed
      assert state.socket == nil
      assert state.stream_ref == nil
      assert state.pending_heartbeat_ref == nil
      assert is_reference(state.reconnect_timer)
    end

    test "gun_down cleans up, schedules reconnect and ignores stale messages", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)
      stub_close()

      start_supervised!({Connection, name: conn_name, registry: registry, store: store, client: @mock_client})
      Process.sleep(50)
      {socket, _stream_ref} = drive_to_open(conn_name)

      send(conn_name, {:gun_down, socket, :http, :normal, []})
      Process.sleep(20)

      assert_received {:gun_closed, ^socket}

      state = :sys.get_state(conn_name)
      assert state.status == :closed
      assert state.socket == nil
      assert state.stream_ref == nil
      assert is_reference(state.reconnect_timer)

      # a stale gun_down and :DOWN from an old gun pid are ignored
      old_socket = spawn(fn -> Process.sleep(:infinity) end)
      send(conn_name, {:gun_down, old_socket, :http, :normal, []})
      send(conn_name, {:DOWN, make_ref(), :process, old_socket, :killed})
      Process.sleep(20)

      state = :sys.get_state(conn_name)
      assert state.status == :closed
      assert state.socket == nil
    end

    test "gun process :DOWN runs the same cleanup", %{registry: registry, store: store, conn_name: conn_name} do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)
      stub_close()

      start_supervised!({Connection, name: conn_name, registry: registry, store: store, client: @mock_client})
      Process.sleep(50)
      {socket, _stream_ref} = drive_to_open(conn_name)

      send(conn_name, {:DOWN, make_ref(), :process, socket, :killed})
      Process.sleep(20)

      assert_received {:gun_closed, ^socket}

      state = :sys.get_state(conn_name)
      assert state.status == :closed
      assert state.socket == nil
      assert state.stream_ref == nil
      assert is_reference(state.reconnect_timer)
    end

    test "failed upgrade does not stop the connection process", %{registry: registry, store: store, conn_name: conn_name} do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)
      stub_close()

      pid = start_supervised!({Connection, name: conn_name, registry: registry, store: store, client: @mock_client})
      Process.sleep(50)
      {socket, stream_ref} = drive_to_open(conn_name)

      send(conn_name, {:gun_response, socket, stream_ref, :fin, 401, []})
      Process.sleep(20)

      assert Process.alive?(pid)

      state = :sys.get_state(pid)
      assert state.status == :closed
      assert is_reference(state.reconnect_timer)
    end
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
      client: @mock_client
    ]

    {:ok, pid} = Connection.start_link(opts)
    Process.sleep(50)

    # Check that basic state is set
    state = :sys.get_state(pid)
    assert state.registry == registry
    assert state.store == store
    assert state.client == @mock_client
    # default
    assert state.heartbeat_interval == 25_000

    # Connection should be attempting to connect
    assert state.status == :connecting
  end
end

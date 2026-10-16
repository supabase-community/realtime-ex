defmodule ConnectionFakeSerializer do
  @moduledoc false
  @behaviour Supabase.Realtime.Serializer

  @collector_key {__MODULE__, :collector_pid}

  def set_collector(pid), do: :persistent_term.put(@collector_key, pid)

  @impl true
  def encode(message, opts) do
    record({:encode, message, opts})
    {:ok, {:text, "fake-encode"}}
  end

  @impl true
  def decode(frame, opts) do
    record({:decode, frame, opts})
    {:ok, %{"topic" => "fake", "event" => "fake", "payload" => %{}, "ref" => nil}}
  end

  defp record(call) do
    case :persistent_term.get(@collector_key, nil) do
      nil -> :ok
      pid -> send(pid, {:fake_serializer, call})
    end
  end
end

defmodule Supabase.Realtime.ConnectionTest do
  # Using async: false as we're mocking global modules
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection
  alias Supabase.Realtime.Message

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

  describe "serializer resolution" do
    test "init defaults to the V1 serializer with vsn 1.0.0", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      pid =
        start_supervised!({Connection, name: conn_name, registry: registry, store: store, client: @mock_client})

      Process.sleep(30)

      state = :sys.get_state(pid)
      assert state.serializer == Supabase.Realtime.Serializer.V1
      assert state.vsn == "1.0.0"
      assert state.serializer_opts == []
    end

    test "init with vsn 2.0.0 selects the V2 serializer", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [name: conn_name, registry: registry, store: store, client: @mock_client, vsn: "2.0.0"]
      pid = start_supervised!({Connection, opts})
      Process.sleep(30)

      state = :sys.get_state(pid)
      assert state.serializer == Supabase.Realtime.Serializer.V2
      assert state.vsn == "2.0.0"
    end

    test "init with an unsupported vsn fails to start", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      opts = [name: conn_name, registry: registry, store: store, client: @mock_client, vsn: "9.9.9"]

      # trapping keeps the linked failing start from killing the test process,
      # so the failure surfaces as a start error carrying the exception
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} = Connection.start_link(opts)
      assert message =~ "invalid Realtime serializer options"
    end

    test "serializer_opts are stored verbatim", %{registry: registry, store: store, conn_name: conn_name} do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: conn_name,
        registry: registry,
        store: store,
        client: @mock_client,
        vsn: "2.0.0",
        serializer_opts: [allowed_metadata_keys: [:user_id]]
      ]

      pid = start_supervised!({Connection, opts})
      Process.sleep(30)

      assert :sys.get_state(pid).serializer_opts == [allowed_metadata_keys: [:user_id]]
    end
  end

  describe "URL negotiation" do
    defp capture_upgrade_path(opts) do
      test = self()

      stub(:gun, :open, fn _, _, _ -> {:ok, test} end)

      stub(:gun, :ws_upgrade, fn _socket, path, _headers ->
        send(test, {:upgrade_path, path})
        make_ref()
      end)

      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      pid = start_supervised!({Connection, opts})
      send(pid, {:gun_up, test, :http})
      assert_receive {:upgrade_path, path}, 1000
      path
    end

    test "default negotiation stays at vsn 1.0.0", %{registry: registry, store: store, conn_name: conn_name} do
      path =
        capture_upgrade_path(name: conn_name, registry: registry, store: store, client: @mock_client)

      assert path =~ "vsn=1.0.0"
    end

    test "the negotiated vsn travels in the query string", %{registry: registry, store: store, conn_name: conn_name} do
      path =
        capture_upgrade_path(name: conn_name, registry: registry, store: store, client: @mock_client, vsn: "2.0.0")

      assert path =~ "vsn=2.0.0"
    end

    test "the negotiated vsn wins over a vsn inside params", %{
      registry: registry,
      store: store,
      conn_name: conn_name
    } do
      path =
        capture_upgrade_path(
          name: conn_name,
          registry: registry,
          store: store,
          client: @mock_client,
          vsn: "2.0.0",
          params: %{vsn: "9.9.9"}
        )

      assert path =~ "vsn=2.0.0"
      refute path =~ "9.9.9"
    end
  end

  describe "serializer wiring" do
    defp start_open_connection(ctx, extra_opts, frames_pid) do
      stub(:gun, :open, fn _, _, _ -> {:ok, frames_pid} end)
      stream_ref = make_ref()
      stub(:gun, :ws_upgrade, fn _, _, _ -> stream_ref end)

      stub(:gun, :ws_send, fn _socket, _stream, frame ->
        send(frames_pid, {:ws_frame, frame})
        :ok
      end)

      stub(:gun, :close, fn _socket -> :ok end)

      conn =
        start_supervised!(
          {Connection,
           [name: ctx.conn_name, registry: ctx.registry, store: ctx.store, client: @mock_client] ++ extra_opts}
        )

      send(conn, {:gun_up, frames_pid, :http})
      send(conn, {:gun_upgrade, frames_pid, stream_ref, ["websocket"], []})
      Process.sleep(30)

      {conn, stream_ref}
    end

    test "V2 sends user broadcasts as kind-3 binary frames", ctx do
      {conn, _stream_ref} = start_open_connection(ctx, [vsn: "2.0.0"], self())
      {:ok, channel} = Registry.create_channel(ctx.registry, "sala")
      {:ok, _updated} = Store.update_join_ref(ctx.store, channel, "7")

      payload = %{type: "broadcast", event: "posição", payload: %{x: 1, y: 2}}

      :ok =
        Connection.send_message(conn, channel, %{event: "broadcast", payload: payload, ref: "42"})

      expected =
        <<3, 1, 2, 13, 9, 0, 1>> <>
          "7" <>
          "42" <>
          "realtime:sala" <>
          "posição" <>
          "" <>
          ~s({"x":1,"y":2})

      assert_received {:ws_frame, {:binary, ^expected}}
    end

    test "V2 sends non-broadcast messages as JSON array text frames", ctx do
      {conn, _stream_ref} = start_open_connection(ctx, [vsn: "2.0.0"], self())

      send(conn, :heartbeat)

      assert_receive {:ws_frame, {:text, json}}, 1000
      assert [nil, ref, "phoenix", "heartbeat", %{}] = JSON.decode!(json)
      assert ref =~ ~r/^msg:[0-9a-f]{20}$/
    end

    test "V1 keeps sending object JSON text frames (no-regression gate)", ctx do
      {conn, _stream_ref} = start_open_connection(ctx, [], self())
      {:ok, channel} = Registry.create_channel(ctx.registry, "room")

      :ok = Connection.send_message(conn, channel, Message.broadcast_message(channel, "ev", %{n: 1}))

      assert_receive {:ws_frame, {:text, broadcast_json}}, 1000
      broadcast = JSON.decode!(broadcast_json)
      assert is_map(broadcast)
      assert broadcast["event"] == "broadcast"
      assert broadcast["topic"] == "realtime:room"
      assert broadcast["payload"] == %{"type" => "broadcast", "event" => "ev", "payload" => %{"n" => 1}}

      send(conn, :heartbeat)

      assert_receive {:ws_frame, {:text, heartbeat_json}}, 1000
      heartbeat = JSON.decode!(heartbeat_json)
      assert is_map(heartbeat)
      assert heartbeat["topic"] == "phoenix"
      assert heartbeat["event"] == "heartbeat"
    end

    test "inbound binary frames decode through V2 and reach the Registry", ctx do
      on_exit(fn -> RealtimeTest.clear_collector() end)

      {conn, stream_ref} = start_open_connection(ctx, [vsn: "2.0.0"], self())
      {:ok, channel} = Registry.create_channel(ctx.registry, "sala")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "posição"})
      RealtimeTest.set_collector(self())

      frame = <<4, 13, 9, 0, 1>> <> "realtime:sala" <> "posição" <> "" <> ~s({"x":1,"y":2})
      send(conn, {:gun_ws, self(), stream_ref, {:binary, frame}})

      assert_receive {:dispatched, {:broadcast, "posição", %{"x" => 1, "y" => 2}}}, 1000
    end

    test "inbound binary frames are logged and dropped under V1", ctx do
      on_exit(fn -> RealtimeTest.clear_collector() end)

      {conn, stream_ref} = start_open_connection(ctx, [], self())
      RealtimeTest.set_collector(self())

      frame = <<4, 13, 9, 0, 1>> <> "realtime:sala" <> "posição" <> "" <> ~s({"x":1,"y":2})

      log =
        capture_log(fn ->
          send(conn, {:gun_ws, self(), stream_ref, {:binary, frame}})
          Process.sleep(50)
        end)

      assert log =~ "failed to decode frame"
      refute_received {:dispatched, _}
      assert Process.alive?(conn)
    end

    test "encode failures are logged and dropped without poisoning the connection", ctx do
      {conn, _stream_ref} = start_open_connection(ctx, [vsn: "2.0.0"], self())

      # a 250-char name gives a 259-byte topic, over the 255-byte field guard
      {:ok, channel} = Registry.create_channel(ctx.registry, String.duplicate("a", 250))

      payload = %{event: "broadcast", payload: %{event: "ev", payload: %{}}}

      log =
        capture_log(fn ->
          assert :ok = Connection.send_message(conn, channel, payload)
        end)

      assert log =~ "failed to encode message"
      assert log =~ "{:field_too_long, :topic, 259}"
      assert Process.alive?(conn)

      # a well-formed message still goes out afterwards
      send(conn, :heartbeat)
      assert_receive {:ws_frame, {:text, _json}}, 1000
    end

    test "junk binary frames are logged and dropped without poisoning the connection", ctx do
      {conn, stream_ref} = start_open_connection(ctx, [vsn: "2.0.0"], self())

      log =
        capture_log(fn ->
          send(conn, {:gun_ws, self(), stream_ref, {:binary, <<255, 1, 2>>}})
          Process.sleep(50)
        end)

      assert log =~ "failed to decode frame"
      assert Process.alive?(conn)
    end

    test "custom serializer option flows to encode/decode with serializer_opts", ctx do
      on_exit(fn -> ConnectionFakeSerializer.set_collector(nil) end)
      ConnectionFakeSerializer.set_collector(self())

      opts = [serializer: ConnectionFakeSerializer, serializer_opts: [custom: :opt]]
      {conn, stream_ref} = start_open_connection(ctx, opts, self())
      {:ok, channel} = Registry.create_channel(ctx.registry, "sala")

      :ok = Connection.send_message(conn, channel, %{event: "e", payload: %{}})

      assert_receive {:fake_serializer, {:encode, message, [custom: :opt]}}, 1000
      assert message[:topic] == "realtime:sala"
      assert_receive {:ws_frame, {:text, "fake-encode"}}, 1000

      send(conn, {:gun_ws, self(), stream_ref, {:text, "raw-inbound"}})
      assert_receive {:fake_serializer, {:decode, {:text, "raw-inbound"}, [custom: :opt]}}, 1000
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

defmodule Supabase.Realtime.HeartbeatTelemetryTest do
  # mocking global modules (:gun)
  use ExUnit.Case, async: false
  use Mimic

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection

  @moduletag capture_log: true

  @heartbeat_event [:supabase, :realtime, :heartbeat]

  @mock_client %Supabase.Client{
    api_key: "mock_api_key",
    realtime_url: "https://example.com",
    base_url: "https://example.com",
    access_token: "mock_token"
  }

  setup do
    set_mimic_global()

    test = self()

    :telemetry.attach(
      "hb-test",
      @heartbeat_event,
      fn _event, measurements, metadata, _config ->
        send(test, {:heartbeat_event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach("hb-test") end)

    registry_name = :"Registry#{System.unique_integer([:positive])}"
    store_name = :"Store#{System.unique_integer([:positive])}"
    conn_name = :"Connection#{System.unique_integer([:positive])}"

    start_supervised!({Store, name: store_name})
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name})

    stub(:gun, :open, fn _, _, _ -> {:ok, test} end)
    stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
    stub(:gun, :ws_send, fn _, _, _ -> :ok end)
    stub(:gun, :close, fn _socket -> :ok end)

    conn =
      start_supervised!({Connection, name: conn_name, registry: registry_name, store: store_name, client: @mock_client})

    Process.sleep(30)

    # drive the connection to :open with a known socket/stream pair
    socket = self()
    stream_ref = make_ref()

    :sys.replace_state(conn, fn state ->
      %{state | socket: socket, stream_ref: stream_ref, status: :connecting}
    end)

    send(conn, {:gun_upgrade, socket, stream_ref, ["websocket"], []})
    Process.sleep(20)

    %{conn: conn, socket: socket, stream_ref: stream_ref}
  end

  test "T1: emits :sent when a heartbeat goes out", ctx do
    send(ctx.conn, :heartbeat)

    assert_receive {:heartbeat_event, measurements, metadata}, 1000
    assert measurements == %{}
    assert metadata.status == :sent
    assert is_binary(metadata.ref)
    assert metadata.client == "https://example.com"

    state = :sys.get_state(ctx.conn)
    assert state.pending_heartbeat_ref == metadata.ref
    assert is_integer(state.heartbeat_sent_at)
  end

  test "T2: emits :ok with round-trip latency on the heartbeat reply", ctx do
    send(ctx.conn, :heartbeat)
    assert_receive {:heartbeat_event, %{}, %{status: :sent, ref: ref}}, 1000

    # pretend the heartbeat left 100ms ago so the latency is deterministic
    :sys.replace_state(ctx.conn, fn state ->
      %{state | heartbeat_sent_at: System.monotonic_time(:millisecond) - 100}
    end)

    reply =
      JSON.encode!(%{
        "topic" => "phoenix",
        "event" => "phx_reply",
        "ref" => ref,
        "payload" => %{"status" => "ok", "response" => %{}}
      })

    send(ctx.conn, {:gun_ws, ctx.socket, ctx.stream_ref, {:text, reply}})

    assert_receive {:heartbeat_event, %{latency: latency}, %{status: :ok, ref: ^ref}}, 1000
    assert latency >= 100

    state = :sys.get_state(ctx.conn)
    assert state.pending_heartbeat_ref == nil
    assert state.heartbeat_sent_at == nil
  end

  test "T3: emits nothing while the connection is closed", ctx do
    :sys.replace_state(ctx.conn, fn state ->
      %{state | status: :closed, socket: nil, stream_ref: nil, heartbeat_timer: nil}
    end)

    send(ctx.conn, :heartbeat)
    Process.sleep(30)

    refute_received {:heartbeat_event, _, _}
  end

  test "T4: every emitted event carries the client base_url", ctx do
    send(ctx.conn, :heartbeat)
    assert_receive {:heartbeat_event, _, sent_metadata}, 1000
    assert sent_metadata.client == @mock_client.base_url

    :sys.replace_state(ctx.conn, fn state ->
      %{state | heartbeat_sent_at: System.monotonic_time(:millisecond) - 50}
    end)

    reply =
      JSON.encode!(%{
        "topic" => "phoenix",
        "event" => "phx_reply",
        "ref" => sent_metadata.ref,
        "payload" => %{"status" => "ok", "response" => %{}}
      })

    send(ctx.conn, {:gun_ws, ctx.socket, ctx.stream_ref, {:text, reply}})

    assert_receive {:heartbeat_event, _, ok_metadata}, 1000
    assert ok_metadata.client == @mock_client.base_url
  end

  test "T5: emits :timeout when the previous heartbeat went unanswered", ctx do
    send(ctx.conn, :heartbeat)
    assert_receive {:heartbeat_event, %{}, %{status: :sent, ref: ref}}, 1000

    # next tick with the ref still pending: dead connection, forced reconnect
    send(ctx.conn, :heartbeat)

    assert_receive {:heartbeat_event, %{}, %{status: :timeout, ref: ^ref}}, 1000
    assert :sys.get_state(ctx.conn).status == :closed
  end
end

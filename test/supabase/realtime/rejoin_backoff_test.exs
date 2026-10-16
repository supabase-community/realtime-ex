defmodule Supabase.Realtime.RejoinBackoffTest do
  use ExUnit.Case, async: false
  use Mimic

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
    set_mimic_global()
    RealtimeTest.set_collector(self())
    on_exit(fn -> RealtimeTest.clear_collector() end)

    unique_id = System.unique_integer([:positive])
    store_name = :"Store#{unique_id}"
    registry_name = :"Registry#{unique_id}"
    conn_name = :"Connection#{unique_id}"

    start_supervised!({Store, name: store_name})

    %{
      registry: registry_name,
      store: store_name,
      conn_name: conn_name
    }
  end

  describe "per-channel rejoin backoff" do
    test "failed join retries on its own with a fresh join_ref", ctx do
      # delay long enough that the :errored intermediate state is observable
      start_registry(ctx, fn _ -> 100 end)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)
      assert join1["event"] == "phx_join"

      send_join_error(conn, stream_ref, channel, join1["ref"])
      stored = wait_for_state(ctx, channel, :errored)
      assert stored.state == :errored

      # the timer fires on its own: a fresh join goes out unprompted
      assert_receive {:ws_frame, {:text, join2_json}}, 1000
      join2 = JSON.decode!(join2_json)

      assert join2["event"] == "phx_join"
      assert join2["ref"] != join1["ref"]
      assert join2["ref"] == join2["join_ref"]

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :joining
    end

    test "backoff advances per fire, not per arm", ctx do
      test = self()

      start_registry(ctx, fn tries ->
        send(test, {:rejoin_tries, tries})
        10
      end)

      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)
      send_join_error(conn, stream_ref, channel, join1["ref"])

      assert_receive {:ws_frame, {:text, join2_json}}, 1000
      join2 = JSON.decode!(join2_json)
      send_join_error(conn, stream_ref, channel, join2["ref"])

      # phoenix Timer semantics: tries counts fired timers
      assert_receive {:rejoin_tries, 1}, 1000
      assert_receive {:rejoin_tries, 2}, 1000
    end

    test "an arm replaced before firing re-reads the same tries", ctx do
      test = self()

      start_registry(ctx, fn tries ->
        send(test, {:rejoin_tries, tries})
        # long enough that the broadcast subscribe lands before arm 1 fires,
        # making the cancel-before-fire ordering deterministic
        100
      end)

      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)
      # join #1 fails: arm 1 armed with tries 1
      send_join_error(conn, stream_ref, channel, join1["ref"])
      wait_for_state(ctx, channel, :errored)

      # a broadcast binding is allowed on :errored; the immediate join
      # replaces the pending retry (cancelling arm 1 before it fired)
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "x"})

      # a stale-token fire (zombie from a cancelled arm) must not join or
      # advance tries: the token no longer matches
      send(Process.whereis(ctx.registry), {:rejoin_timer, channel.ref, make_ref()})

      assert_receive {:ws_frame, {:text, join2_json}}, 1000
      join2 = JSON.decode!(join2_json)
      assert join2["event"] == "phx_join"
      send_join_error(conn, stream_ref, channel, join2["ref"])

      # the replacement arm re-reads tries 0 -> delay call gets 1 again;
      # arm 1's zombie fire (if delivered) must not join or advance tries
      assert_receive {:rejoin_tries, 1}, 1000
      assert_receive {:rejoin_tries, 1}, 1000
      refute_receive {:rejoin_tries, 2}, 100
    end

    test "successful join cancels retries", ctx do
      start_registry(ctx, fn _ -> 10 end)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)
      send_join_error(conn, stream_ref, channel, join1["ref"])

      assert_receive {:ws_frame, {:text, join2_json}}, 1000
      join2 = JSON.decode!(join2_json)

      reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => join2["ref"],
        "payload" => %{"status" => "ok", "response" => %{}}
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})
      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :joined

      refute_receive {:ws_frame, _}, 150
      refute_receive {:rejoin_tries, _}, 150
    end

    test "unsubscribe cancels retries", ctx do
      start_registry(ctx, fn _ -> 100 end)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)
      send_join_error(conn, stream_ref, channel, join1["ref"])
      wait_for_state(ctx, channel, :errored)

      :ok = Registry.unsubscribe(ctx.registry, channel)

      assert_receive {:ws_frame, {:text, leave_json}}, 1000
      leave = JSON.decode!(leave_json)
      assert leave["event"] == "phx_leave"

      # no rejoin frame after the leave; the channel stays :leaving
      refute_receive {:ws_frame, _}, 150

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :leaving
    end

    test "connection down clears armed retries; the sweep rejoins on reopen", ctx do
      # 100ms: if the timer were NOT cleared by the :closed notification it
      # would fire inside the refute window below
      start_registry(ctx, fn _ -> 100 end)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)
      send_join_error(conn, stream_ref, channel, join1["ref"])
      wait_for_state(ctx, channel, :errored)

      send(conn, {:gun_down, self(), :http, :closed, []})
      Process.sleep(20)

      refute_receive {:ws_frame, _}, 150

      # drive the landed reconnect sequence
      send(conn, :reconnect)
      Process.sleep(20)
      send(conn, {:gun_up, self(), :http})
      Process.sleep(20)

      current_ref = :sys.get_state(conn).stream_ref
      send(conn, {:gun_upgrade, self(), current_ref, ["websocket"], []})

      assert_receive {:ws_frame, {:text, rejoin_json}}, 1000
      rejoin = JSON.decode!(rejoin_json)

      assert rejoin["event"] == "phx_join"
      assert rejoin["topic"] == channel.topic
      assert rejoin["ref"] != join1["ref"]
      assert rejoin["ref"] == rejoin["join_ref"]
    end

    test "timer fire with a dead connection drops the entry without crashing", ctx do
      start_registry(ctx, fn _ -> 100 end)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)
      send_join_error(conn, stream_ref, channel, join1["ref"])
      stored = wait_for_state(ctx, channel, :errored)
      assert stored.state == :errored

      # stop by child id: stop_supervised!/1 expects the child spec's :id,
      # not the pid (terminate_child/2 by pid returns {:error, :not_found})
      stop_supervised!(Connection)
      Process.sleep(150)

      # the fire found a dead connection: no crash, no state change
      assert ctx.registry |> Process.whereis() |> Process.alive?()

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :errored
    end

    test "registry-only: timer fire with no connection drops the entry without a state change", ctx do
      registry =
        start_supervised!(
          {Registry, module: RealtimeTest, name: ctx.registry, store: ctx.store, rejoin_after_ms: fn _ -> 10 end}
        )

      {:ok, channel} = Registry.create_channel(registry, "public:users")

      :ok =
        Registry.subscribe(registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      Process.sleep(50)

      # no Connection is running: set the join_ref manually and feed the
      # error reply through handle_message. Store updates replace the whole
      # struct, so re-read the stored channel first.
      {:ok, current} = Store.find_by_ref(ctx.store, channel.ref)
      {:ok, channel} = Store.update_join_ref(ctx.store, current, "jr-1")
      {:ok, _} = Store.update_state(ctx.store, channel, :joining)

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => "jr-1",
        "payload" => %{"status" => "error", "response" => %{"reason" => "unauthorized"}}
      })

      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :errored

      # past the 10ms delay: the fire drops the entry, no join, no crash
      Process.sleep(50)

      assert Process.alive?(registry)

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :errored
    end
  end

  # Helpers

  # The :open sweep re-joins channels in :joining/:joined/:errored, so a
  # subscribe racing the :open notification would be joined twice (the
  # sweep's join supersedes the first frame's join_ref). Creating the
  # channel before the connection opens and waiting for the dispatched :open
  # state change makes the subscribe strictly post-sweep: its join is the
  # only one in flight.
  defp wait_connection_open do
    assert_receive {:dispatched, {:connection, :state_change, %{new: :open}}}, 1000
  end

  # The error reply travels gun_ws -> Connection -> Registry cast; poll the
  # Store for the resulting state instead of sleeping a fixed interval.
  defp wait_for_state(ctx, channel, expected) do
    deadline = System.monotonic_time(:millisecond) + 1000
    do_wait_for_state(ctx, channel, expected, deadline)
  end

  defp do_wait_for_state(ctx, channel, expected, deadline) do
    {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)

    cond do
      stored.state == expected ->
        stored

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("channel did not reach #{inspect(expected)}, still #{inspect(stored.state)}")

      true ->
        Process.sleep(2)
        do_wait_for_state(ctx, channel, expected, deadline)
    end
  end

  defp start_registry(ctx, rejoin_after_ms) do
    start_supervised!(
      {Registry,
       module: RealtimeTest,
       name: ctx.registry,
       store: ctx.store,
       connection: ctx.conn_name,
       rejoin_after_ms: rejoin_after_ms}
    )
  end

  defp start_connection(ctx) do
    test = self()
    stream_ref = make_ref()

    stub(:gun, :open, fn _, _, _ -> {:ok, test} end)
    stub(:gun, :ws_upgrade, fn _, _, _ -> stream_ref end)
    stub(:gun, :close, fn _ -> :ok end)

    stub(:gun, :ws_send, fn _socket, _stream, frame ->
      send(test, {:ws_frame, frame})
      :ok
    end)

    conn =
      start_supervised!(
        {Connection,
         name: ctx.conn_name,
         registry: ctx.registry,
         store: ctx.store,
         client: @mock_client,
         heartbeat_interval: to_timeout(minute: 5)}
      )

    send(conn, {:gun_up, test, :http})
    send(conn, {:gun_upgrade, test, stream_ref, ["websocket"], []})
    Process.sleep(30)

    {conn, stream_ref}
  end

  defp send_join_error(conn, stream_ref, channel, join_ref) do
    reply = %{
      "topic" => channel.topic,
      "event" => "phx_reply",
      "ref" => join_ref,
      "payload" => %{"status" => "error", "response" => %{"reason" => "unauthorized"}}
    }

    send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})
  end
end

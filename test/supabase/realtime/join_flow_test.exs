defmodule Supabase.Realtime.JoinFlowTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Supabase.Realtime
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
    set_mimic_global()
    RealtimeTest.set_collector(self())
    on_exit(fn -> RealtimeTest.clear_collector() end)

    unique_id = System.unique_integer([:positive])
    store_name = :"Store#{unique_id}"
    registry_name = :"Registry#{unique_id}"
    conn_name = :"Connection#{unique_id}"

    start_supervised!({Store, name: store_name})
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name, connection: conn_name})

    %{
      registry: registry_name,
      store: store_name,
      conn_name: conn_name
    }
  end

  describe "join flow (P0.2)" do
    test "subscribe sends the protocol-correct phx_join frame", ctx do
      start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users",
          filter: "id=eq.1"
        })

      assert_receive {:ws_frame, {:text, json}}, 1000
      frame = JSON.decode!(json)

      assert frame["topic"] == "realtime:public:users"
      assert frame["event"] == "phx_join"
      assert frame["ref"] == frame["join_ref"]

      config = frame["payload"]["config"]

      assert config["postgres_changes"] == [
               %{"event" => "INSERT", "schema" => "public", "table" => "users", "filter" => "id=eq.1"}
             ]

      assert config["presence"] == %{"key" => "", "enabled" => false}
      assert config["broadcast"] == %{"ack" => false, "self" => false}
      assert config["private"] == false
      assert frame["payload"]["access_token"] == "mock_token"
    end

    test "join reply marks the channel joined, sets binding ids and flushes the push buffer", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join_json}}, 1000
      join = JSON.decode!(join_json)

      # a broadcast sent while joining is push-buffered (no frame goes out)
      :ok = Connection.send_message(conn, channel, Message.broadcast_message(channel, "ev", %{"n" => 1}))
      conn_state = :sys.get_state(conn)
      assert :queue.len(conn_state.push_buffers[channel.topic]) == 1

      reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => join["ref"],
        "payload" => %{
          "status" => "ok",
          "response" => %{
            "postgres_changes" => [
              %{"id" => 106_243_155, "event" => "INSERT", "schema" => "public", "table" => "users"}
            ]
          }
        }
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})

      assert_receive {:ws_frame, {:text, flushed_json}}, 1000
      flushed = JSON.decode!(flushed_json)
      assert flushed["event"] == "broadcast"
      assert flushed["join_ref"] == join["ref"]

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :joined
      [binding] = stored.bindings["postgres_changes"]
      assert binding.id == 106_243_155
    end

    test "join race: postgres_changes/presence bindings added while joining or joined are rejected", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert {:error, :already_joining} =
               Registry.subscribe(ctx.registry, channel, "postgres_changes", %{event: :delete, schema: "public"})

      assert {:error, :already_joining} = Registry.subscribe(ctx.registry, channel, "presence", %{})

      # broadcast bindings stay allowed while joining
      assert :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "x"})

      assert_receive {:ws_frame, {:text, join_json}}, 1000

      reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => JSON.decode!(join_json)["ref"],
        "payload" => %{"status" => "ok", "response" => %{}}
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})
      Process.sleep(50)

      assert {:error, :already_joined} =
               Registry.subscribe(ctx.registry, channel, "postgres_changes", %{event: :update, schema: "public"})

      assert {:error, :already_joined} = Registry.subscribe(ctx.registry, channel, "presence", %{})
      assert :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "y"})

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert length(stored.bindings["broadcast"]) == 2
    end

    test "rejoins channels with a fresh join_ref and persisted token after reconnect", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join_json}}, 1000
      first_join = JSON.decode!(join_json)

      reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => first_join["ref"],
        "payload" => %{"status" => "ok", "response" => %{}}
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})
      Process.sleep(50)

      # the persisted token is applied on the rejoin payload
      assert :ok = Connection.set_auth(conn, "tok2")
      assert_receive {:ws_frame, {:text, token_json}}, 1000
      assert JSON.decode!(token_json)["event"] == "access_token"

      send(conn, {:gun_down, self(), :http, :closed, []})
      Process.sleep(20)
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
      assert rejoin["ref"] != first_join["ref"]
      assert rejoin["ref"] == rejoin["join_ref"]
      assert rejoin["payload"]["access_token"] == "tok2"
    end

    test "duplicate postgres binding never reaches the join payload", ctx do
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")
      {conn, stream_ref} = start_connection(ctx)
      wait_connection_open()

      filter = %{event: :insert, schema: "public", table: "users"}

      :ok = Registry.subscribe(ctx.registry, channel, "postgres_changes", filter)

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)

      # force :errored by replying an error to the join
      send_join_error(conn, stream_ref, channel, join1["ref"])
      wait_for_state(ctx, channel, :errored)

      assert {:error, :duplicate_binding} = Registry.subscribe(ctx.registry, channel, "postgres_changes", filter)

      # drive a fresh connection: the :open sweep rejoins the errored channel
      send(conn, {:gun_down, self(), :http, :closed, []})
      Process.sleep(20)
      send(conn, :reconnect)
      Process.sleep(20)
      send(conn, {:gun_up, self(), :http})
      Process.sleep(20)

      current_ref = :sys.get_state(conn).stream_ref
      send(conn, {:gun_upgrade, self(), current_ref, ["websocket"], []})

      assert_receive {:ws_frame, {:text, rejoin_json}}, 1000
      rejoin = JSON.decode!(rejoin_json)

      assert rejoin["event"] == "phx_join"
      assert length(rejoin["payload"]["config"]["postgres_changes"]) == 1
    end

    test "two distinct postgres bindings: oldest-first in the join payload and aligned server ids", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join1_json}}, 1000
      join1 = JSON.decode!(join1_json)

      # force :errored so the second binding can be added
      send_join_error(conn, stream_ref, channel, join1["ref"])
      Process.sleep(30)

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :update,
          schema: "public",
          table: "posts"
        })

      assert_receive {:ws_frame, {:text, join2_json}}, 1000
      join2 = JSON.decode!(join2_json)

      # the wire list is oldest-first (realtime-js parity): the first
      # subscribed binding comes first, which keeps the server's positional
      # binding ids aligned with the stored bindings
      assert join2["payload"]["config"]["postgres_changes"] == [
               %{"event" => "INSERT", "schema" => "public", "table" => "users"},
               %{"event" => "UPDATE", "schema" => "public", "table" => "posts"}
             ]

      # the server echoes bindings in payload order
      send_join_ok(conn, stream_ref, channel, join2["ref"], [
        %{"id" => 1, "event" => "INSERT", "schema" => "public", "table" => "users"},
        %{"id" => 2, "event" => "UPDATE", "schema" => "public", "table" => "posts"}
      ])

      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)

      # alignment, not just set membership: each binding holds the id of
      # ITS subscription
      by_event = Map.new(stored.bindings["postgres_changes"], fn binding -> {binding.filter.event, binding.id} end)
      assert by_event == %{insert: 1, update: 2}
    end

    test "incoming postgres_changes dispatches with transformed record", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join_json}}, 1000

      send_join_ok(conn, stream_ref, channel, JSON.decode!(join_json)["ref"], [
        %{"id" => 106_243_155, "event" => "INSERT", "schema" => "public", "table" => "users"}
      ])

      msg = %{
        "topic" => channel.topic,
        "event" => "postgres_changes",
        "ref" => nil,
        "join_ref" => nil,
        "payload" => %{
          "ids" => [106_243_155],
          "data" => %{
            "schema" => "public",
            "table" => "users",
            "commit_timestamp" => "2025-11-19T00:22:40.877Z",
            "type" => "INSERT",
            "columns" => [%{"name" => "id", "type" => "int8"}],
            "record" => %{"id" => "46"},
            "old_record" => %{},
            "errors" => nil
          }
        }
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(msg)}})

      assert_receive {:dispatched, {:postgres_changes, :insert, payload}}, 1000
      assert payload["record"] == %{"id" => 46}
      assert payload["table"] == "users"
      assert payload["schema"] == "public"
      assert payload["type"] == "INSERT"
      assert payload["old_record"] == %{}
    end

    test "incoming broadcast dispatches by inner event name only to matching channels", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "cursor-pos"})
      Process.sleep(50)

      msg = %{
        "topic" => channel.topic,
        "event" => "broadcast",
        "ref" => nil,
        "join_ref" => nil,
        "payload" => %{
          "type" => "broadcast",
          "event" => "cursor-pos",
          "meta" => %{"id" => "uuid"},
          "payload" => %{"x" => 1}
        }
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(msg)}})
      assert_receive {:dispatched, {:broadcast, "cursor-pos", %{"x" => 1}}}, 1000

      # non-matching event name
      other = put_in(msg, ["payload", "event"], "other-event")
      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(other)}})
      refute_receive {:dispatched, {:broadcast, "other-event", _}}, 200

      # a channel with zero broadcast bindings receives nothing
      {:ok, bare} = Registry.create_channel(ctx.registry, "bare")
      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(%{msg | "topic" => bare.topic})}})
      refute_receive {:dispatched, {:broadcast, _name, _payload}}, 200
    end

    test "unsubscribe sends phx_leave with its own ref and removes on ok reply", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "x"})

      assert_receive {:ws_frame, {:text, join_json}}, 1000
      join = JSON.decode!(join_json)
      send_join_ok(conn, stream_ref, channel, join["ref"])
      Process.sleep(50)

      :ok = Realtime.unsubscribe(channel)

      assert_receive {:ws_frame, {:text, leave_json}}, 1000
      leave = JSON.decode!(leave_json)
      assert leave["event"] == "phx_leave"
      assert leave["ref"] != join["ref"]
      assert leave["join_ref"] == join["ref"]
      assert leave["payload"] == %{}

      reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => leave["ref"],
        "payload" => %{"status" => "ok", "response" => %{}}
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})
      Process.sleep(50)

      assert {:error, :not_found} = Store.find_by_ref(ctx.store, channel.ref)
    end

    test "phx_close removes the channel without crashing on the empty payload", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room")

      send(
        conn,
        {:gun_ws, self(), stream_ref,
         {:text,
          JSON.encode!(%{
            "topic" => channel.topic,
            "event" => "phx_close",
            "payload" => %{},
            "ref" => "1",
            "join_ref" => "1"
          })}}
      )

      Process.sleep(50)
      assert {:error, :not_found} = Store.find_by_ref(ctx.store, channel.ref)
    end

    test "phx_error marks the channel errored", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room")

      send(
        conn,
        {:gun_ws, self(), stream_ref,
         {:text,
          JSON.encode!(%{
            "topic" => channel.topic,
            "event" => "phx_error",
            "payload" => %{},
            "ref" => "1",
            "join_ref" => "1"
          })}}
      )

      Process.sleep(50)
      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.state == :errored
    end

    test "unknown events are logged and ignored", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "x"})
      Process.sleep(50)

      send(
        conn,
        {:gun_ws, self(), stream_ref,
         {:text,
          JSON.encode!(%{
            "topic" => channel.topic,
            "event" => "mystery_event",
            "payload" => %{"anything" => true},
            "ref" => nil,
            "join_ref" => nil
          })}}
      )

      Process.sleep(50)
      refute_receive {:dispatched, _}, 100
    end
  end

  describe "ack flow (P0.3)" do
    test "broadcast_with_ack carries the ack_ref as the wire ref and is acknowledged", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room", broadcast: [ack: true])
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "x"})

      assert_receive {:ws_frame, {:text, join_json}}, 1000
      join = JSON.decode!(join_json)
      send_join_ok(conn, stream_ref, channel, join["ref"])
      Process.sleep(50)

      {:ok, ack_ref} = Realtime.broadcast_with_ack(conn, channel, "ev", %{"x" => 1})

      assert_receive {:ws_frame, {:text, broadcast_json}}, 1000
      broadcast = JSON.decode!(broadcast_json)
      assert broadcast["ref"] == ack_ref
      assert broadcast["join_ref"] == join["ref"]

      reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => ack_ref,
        "payload" => %{"status" => "ok", "response" => %{}}
      }

      send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})

      assert {:ok, :acknowledged} = Realtime.wait_for_ack(ack_ref, timeout: 1000)

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.pending_acks == %{}

      refute_receive {:ack_timeout, ^ack_ref}, 100
    end

    test "broadcast_with_ack times out when no reply arrives", ctx do
      {conn, _stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room", broadcast: [ack: true], timeout: 50)
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "x"})
      Process.sleep(50)

      {:ok, ack_ref} = Realtime.broadcast_with_ack(conn, channel, "ev", %{"x" => 1})
      assert {:error, :timeout} = Realtime.wait_for_ack(ack_ref, timeout: 500)

      Process.sleep(100)

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.pending_acks == %{}
    end

    test "broadcast_with_ack while disconnected registers the ack and flushes with the same ref", ctx do
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
          {Connection, name: ctx.conn_name, registry: ctx.registry, store: ctx.store, client: @mock_client}
        )

      Process.sleep(50)

      # closed but with the socket refs intact, so the next gun_upgrade opens
      :sys.replace_state(conn, fn state -> %{state | status: :closed} end)

      {:ok, channel} = Registry.create_channel(ctx.registry, "room", broadcast: [ack: true])
      {:ok, ack_ref} = Realtime.broadcast_with_ack(conn, channel, "ev", %{"x" => 1})

      conn_state = :sys.get_state(conn)
      assert conn_state.send_buffer_size == 1

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert Map.has_key?(stored.pending_acks, ack_ref)

      # drive to open: the send buffer is flushed with the ack ref preserved
      send(conn, {:gun_up, test, :http})
      send(conn, {:gun_upgrade, test, stream_ref, ["websocket"], []})

      assert_receive {:ws_frame, {:text, flushed_json}}, 1000
      assert JSON.decode!(flushed_json)["ref"] == ack_ref
    end
  end

  describe "channel lifecycle (P0.4)" do
    test "join_ref stays stable across broadcasts", ctx do
      {conn, stream_ref} = start_connection(ctx)
      {:ok, channel} = Registry.create_channel(ctx.registry, "room")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "x"})

      assert_receive {:ws_frame, {:text, join_json}}, 1000
      join = JSON.decode!(join_json)
      send_join_ok(conn, stream_ref, channel, join["ref"])
      Process.sleep(50)

      for i <- 1..3 do
        :ok = Connection.send_message(conn, channel, Message.broadcast_message(channel, "ev", %{n: i}))
        assert_receive {:ws_frame, {:text, bjson}}, 1000
        assert JSON.decode!(bjson)["join_ref"] == join["ref"]
      end

      {:ok, stored} = Store.find_by_ref(ctx.store, channel.ref)
      assert stored.join_ref == join["ref"]
    end

    test "set_auth persists across disconnects and reaches the next join", ctx do
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
          {Connection, name: ctx.conn_name, registry: ctx.registry, store: ctx.store, client: @mock_client}
        )

      # gun_up completes the upgrade so the socket refs are in place; then the
      # connection is closed (refs intact) with no token pushed
      send(conn, {:gun_up, test, :http})
      Process.sleep(20)

      :sys.replace_state(conn, fn state -> %{state | status: :closed} end)

      # disconnected: the token is still persisted and applied on the next join
      assert :ok = Connection.set_auth(conn, "persisted_token")

      send(conn, {:gun_upgrade, test, stream_ref, ["websocket"], []})
      Process.sleep(30)

      {:ok, channel} = Registry.create_channel(ctx.registry, "public:users")

      :ok =
        Registry.subscribe(ctx.registry, channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      assert_receive {:ws_frame, {:text, join_json}}, 1000
      assert JSON.decode!(join_json)["payload"]["access_token"] == "persisted_token"
    end
  end

  # Helpers

  # The :open sweep re-joins channels in :joining/:joined/:errored, so a
  # subscribe racing the :open notification would be joined twice (the
  # sweep's join supersedes the first frame's join_ref). Creating the
  # channel before the connection opens and waiting for the dispatched :open
  # state change makes the subscribe strictly post-sweep.
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

  defp send_join_ok(conn, stream_ref, channel, join_ref, server_bindings \\ []) do
    reply = %{
      "topic" => channel.topic,
      "event" => "phx_reply",
      "ref" => join_ref,
      "payload" => %{"status" => "ok", "response" => %{"postgres_changes" => server_bindings}}
    }

    send(conn, {:gun_ws, self(), stream_ref, {:text, JSON.encode!(reply)}})
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

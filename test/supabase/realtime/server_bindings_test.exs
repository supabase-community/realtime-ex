defmodule Supabase.Realtime.ServerBindingsTest do
  use ExUnit.Case, async: false

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store

  @moduletag capture_log: true

  setup do
    unique_id = System.unique_integer([:positive])
    store_name = :"Store#{unique_id}"
    table_name = :"table#{unique_id}"
    registry_name = :"Registry#{unique_id}"

    start_supervised!({Store, name: store_name, table_name: table_name})
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name})

    {:ok, channel} = Registry.create_channel(registry_name, "test_topic")

    {:ok, %{registry: registry_name, store: store_name, channel: channel}}
  end

  describe "server binding validation" do
    test "updates binding ids from server join reply", ctx do
      # Add postgres_changes bindings
      filter1 = %{event: "INSERT", schema: "public", table: "users"}
      filter2 = %{event: "UPDATE", schema: "public", table: "posts"}
      {:ok, channel} = Store.add_binding(ctx.store, ctx.channel, "postgres_changes", filter1)
      {:ok, channel} = Store.add_binding(ctx.store, channel, "postgres_changes", filter2)

      # Set join_ref for the channel
      {:ok, channel} = Store.update_join_ref(ctx.store, channel, "join_ref_1")
      {:ok, _} = Store.update_state(ctx.store, channel, :joining)

      # Simulate server join reply with binding IDs
      server_reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => "join_ref_1",
        "payload" => %{
          "status" => "ok",
          "response" => %{
            "postgres_changes" => [
              %{"id" => 1, "event" => "INSERT", "schema" => "public", "table" => "users"},
              %{"id" => 2, "event" => "UPDATE", "schema" => "public", "table" => "posts"}
            ]
          }
        }
      }

      Registry.handle_message(ctx.registry, server_reply)
      Process.sleep(100)

      {:ok, updated} = Store.find_by_ref(ctx.store, channel.ref)
      bindings = Map.get(updated.bindings, "postgres_changes", [])

      ids = Enum.map(bindings, & &1.id)
      assert 1 in ids
      assert 2 in ids
    end

    test "ignores reply without postgres_changes response", ctx do
      {:ok, channel} = Store.update_join_ref(ctx.store, ctx.channel, "join_ref_2")
      {:ok, _} = Store.update_state(ctx.store, channel, :joining)

      server_reply = %{
        "topic" => channel.topic,
        "event" => "phx_reply",
        "ref" => "join_ref_2",
        "payload" => %{
          "status" => "ok",
          "response" => %{}
        }
      }

      Registry.handle_message(ctx.registry, server_reply)
      Process.sleep(50)

      {:ok, updated} = Store.find_by_ref(ctx.store, channel.ref)
      assert updated.state == :joined
    end
  end
end

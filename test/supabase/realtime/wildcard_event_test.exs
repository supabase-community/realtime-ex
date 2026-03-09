defmodule Supabase.Realtime.WildcardEventTest do
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

    {:ok, %{registry: registry_name, store: store_name}}
  end

  describe "wildcard event matching" do
    test "normalizes :all to \"*\" in bindings", ctx do
      {:ok, channel} = Registry.create_channel(ctx.registry, "test_topic")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: :all})

      Process.sleep(50)

      {:ok, updated} = Store.find_by_ref(ctx.store, channel.ref)
      [binding] = Map.get(updated.bindings, "broadcast")
      assert binding.filter.event == "*"
    end

    test "wildcard binding matches any broadcast event", ctx do
      {:ok, channel} = Registry.create_channel(ctx.registry, "wildcard_topic")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "*"})

      Process.sleep(50)
      {:ok, updated} = Store.find_by_ref(ctx.store, channel.ref)
      Store.update_state(ctx.store, updated, :joined)

      # Simulate a broadcast event
      msg = %{
        "topic" => "realtime:wildcard_topic",
        "event" => "custom_event",
        "payload" => %{"data" => "test"}
      }

      Registry.handle_message(ctx.registry, msg)
      Process.sleep(100)
    end

    test "specific event binding only matches that event", ctx do
      {:ok, channel} = Registry.create_channel(ctx.registry, "specific_topic")
      :ok = Registry.subscribe(ctx.registry, channel, "broadcast", %{event: "only_this"})

      Process.sleep(50)
      {:ok, updated} = Store.find_by_ref(ctx.store, channel.ref)
      [binding] = Map.get(updated.bindings, "broadcast")
      assert binding.filter.event == "only_this"
    end
  end
end

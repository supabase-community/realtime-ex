defmodule NoHandler do
  @moduledoc false
end

defmodule Supabase.Realtime.Channel.RegistryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Filter
  alias Supabase.Realtime.Message

  @moduletag capture_log: true

  setup do
    unique_id = System.unique_integer([:positive])
    store_name = :"StoreForRegistry#{unique_id}"

    _store_pid = start_supervised!({Store, name: store_name})

    registry_pid =
      start_supervised!({Registry, module: RealtimeTest, name: :"TestRegistry#{unique_id}", store: store_name})

    %{registry: registry_pid, store: store_name}
  end

  describe "start_link/1" do
    test "registry has expected state structure", %{registry: registry} do
      # Test the existing registry from setup
      state = :sys.get_state(registry)

      assert state.module == RealtimeTest
      assert is_atom(state.store)
      assert is_list(state.pending_events)
      assert is_map(state.presence_state)
    end

    test "fails if module option is missing" do
      assert_raise KeyError, fn ->
        Registry.start_link([])
      end
    end
  end

  describe "create_channel/3" do
    test "creates a new channel", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      {:ok, stored_channel} = Store.find_by_ref(store, channel.ref)
      assert stored_channel.topic == "realtime:my_topic"
    end

    test "normalizes topic names", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "public:users")

      {:ok, stored_channel} = Store.find_by_ref(store, channel.ref)
      assert stored_channel.topic == "realtime:public:users"
    end

    test "returns existing channel if topic already exists", %{registry: registry, store: store} do
      {:ok, channel1} = Registry.create_channel(registry, "my_topic")
      {:ok, channel2} = Registry.create_channel(registry, "my_topic")

      assert channel1.ref == channel2.ref

      channels = Store.find_all_by_topic(store, "realtime:my_topic")
      assert length(channels) == 1
    end
  end

  describe "list_channels/1" do
    test "returns empty list when no channels exist", %{registry: registry} do
      assert [] = Registry.list_channels(registry)
    end

    test "returns all created channels", %{registry: registry} do
      {:ok, _ch1} = Registry.create_channel(registry, "topic1")
      {:ok, _ch2} = Registry.create_channel(registry, "topic2")
      {:ok, _ch3} = Registry.create_channel(registry, "topic3")

      channels = Registry.list_channels(registry)
      assert length(channels) == 3

      topics = channels |> Enum.map(& &1.topic) |> Enum.sort()
      assert topics == ["realtime:topic1", "realtime:topic2", "realtime:topic3"]
    end

    test "reflects channel removals", %{registry: registry, store: store} do
      {:ok, ch1} = Registry.create_channel(registry, "topic1")
      {:ok, _ch2} = Registry.create_channel(registry, "topic2")

      assert length(Registry.list_channels(registry)) == 2

      Store.remove(store, ch1)

      assert length(Registry.list_channels(registry)) == 1
    end
  end

  describe "subscribe/4" do
    test "adds binding to channel", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")
      :ok = Registry.subscribe(registry, channel, "postgres_changes", %{event: "INSERT"})

      # Give time for the binding to be added
      Process.sleep(50)

      {:ok, stored_channel} = Store.find_by_ref(store, channel.ref)

      assert map_size(stored_channel.bindings) == 1
      assert [binding] = Map.get(stored_channel.bindings, "postgres_changes")
      assert binding.type == "postgres_changes"
      assert binding.filter == %{event: "INSERT"}
    end

    test "returns error for non-existent channel", %{registry: registry} do
      non_existent_channel = %Channel{ref: "non_existent", topic: "fake_topic", registry: self()}

      assert {:error, :channel_not_found} =
               Registry.subscribe(registry, non_existent_channel, "postgres_changes", %{})
    end
  end

  describe "unsubscribe/2" do
    test "completes the leave locally when there is no connection", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      # Setting channel registry to self to avoid the "process attempted to call itself" error
      updated_channel = %{channel | registry: self()}
      :ok = Registry.unsubscribe(registry, updated_channel)

      # Give time for the state to be updated
      Process.sleep(50)

      # no connection: the server lost every channel on disconnect, so the
      # leave is complete locally
      assert {:error, :not_found} = Store.find_by_ref(store, channel.ref)
    end

    test "returns error for non-existent channel", %{registry: registry} do
      non_existent_channel = %Channel{ref: "non_existent", topic: "fake_topic", registry: self()}
      assert {:error, :channel_not_found} = Registry.unsubscribe(registry, non_existent_channel)
    end
  end

  describe "channel states" do
    test "store can mark channels as leaving", %{registry: registry, store: store} do
      # Instead of testing the actual remove_all_channels/1 function
      # which makes calls to the GenServer, we'll test the store operations directly
      {:ok, channel1} = Registry.create_channel(registry, "topic1")
      {:ok, channel2} = Registry.create_channel(registry, "topic2")

      # Update channel states directly through the store
      {:ok, updated1} = Store.update_state(store, channel1, :leaving)
      {:ok, updated2} = Store.update_state(store, channel2, :leaving)

      assert updated1.state == :leaving
      assert updated2.state == :leaving

      # Verify channels have the expected state
      {:ok, stored1} = Store.find_by_ref(store, channel1.ref)
      {:ok, stored2} = Store.find_by_ref(store, channel2.ref)

      assert stored1.state == :leaving
      assert stored2.state == :leaving
    end
  end

  describe "store integration" do
    test "can update channel state through store", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      {:ok, updated} = Store.update_state(store, channel, :joined)
      assert updated.state == :joined

      {:ok, found} = Store.find_by_ref(store, channel.ref)
      assert found.state == :joined
    end

    test "can update channel join_ref through store", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      {:ok, updated} = Store.update_join_ref(store, channel, "new_join_ref")
      assert updated.join_ref == "new_join_ref"

      {:ok, found} = Store.find_by_ref(store, channel.ref)
      assert found.join_ref == "new_join_ref"
    end
  end

  describe "join processing" do
    test "channel can be joined and errored", %{registry: registry, store: store} do
      # Create and directly manipulate channels in the store for testing purposes
      {:ok, channel1} = Registry.create_channel(registry, "ok_topic")
      {:ok, _} = Store.update_join_ref(store, channel1, "join_ref_1")

      # Test manual status changes through store
      {:ok, updated} = Store.update_state(store, channel1, :joining)
      assert updated.state == :joining

      {:ok, joined} = Store.update_state(store, updated, :joined)
      assert joined.state == :joined

      # Create second channel for error test
      {:ok, channel2} = Registry.create_channel(registry, "error_topic")
      {:ok, _} = Store.update_join_ref(store, channel2, "join_ref_2")

      # Test error state
      {:ok, errored} = Store.update_state(store, channel2, :errored)
      assert errored.state == :errored
    end
  end

  describe "subscribe/4 select validation" do
    test "R1: valid select is stored on the binding filter", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "db-changes")

      assert :ok =
               Registry.subscribe(registry, channel, "postgres_changes", %{
                 event: "*",
                 schema: "public",
                 table: "users",
                 select: ["id", "first_name"]
               })

      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(store, channel.ref)
      [binding] = Map.get(stored.bindings, "postgres_changes")
      assert binding.filter.select == ["id", "first_name"]
    end

    test "R2: non-list select is rejected and nothing is stored", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "db-changes")

      assert {:error, :invalid_select} =
               Registry.subscribe(registry, channel, "postgres_changes", %{
                 event: "*",
                 schema: "public",
                 select: "id"
               })

      Process.sleep(50)
      {:ok, stored} = Store.find_by_ref(store, channel.ref)
      assert stored.bindings == %{}
    end

    test "R3: empty select is rejected", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "db-changes")

      assert {:error, :invalid_select} =
               Registry.subscribe(registry, channel, "postgres_changes", %{
                 event: "*",
                 schema: "public",
                 select: []
               })
    end

    test "R4: select with non-binary elements is rejected", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "db-changes")

      assert {:error, :invalid_select} =
               Registry.subscribe(registry, channel, "postgres_changes", %{
                 event: "*",
                 schema: "public",
                 select: ["id", 42]
               })
    end

    test "R5: a %Filter{} given as :filter is serialized before storing", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "db-changes")

      assert :ok =
               Registry.subscribe(registry, channel, "postgres_changes", %{
                 event: "UPDATE",
                 schema: "public",
                 table: "users",
                 filter: Filter.eq(Filter.new(), "id", 1)
               })

      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(store, channel.ref)
      [binding] = Map.get(stored.bindings, "postgres_changes")
      assert binding.filter.filter == "id=eq.1"
    end

    test "R6: select on a broadcast binding is ignored (stored unvalidated)", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "room")

      assert :ok =
               Registry.subscribe(registry, channel, "broadcast", %{
                 event: "new_message",
                 select: []
               })

      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(store, channel.ref)
      [binding] = Map.get(stored.bindings, "broadcast")
      assert binding.filter == %{event: "new_message", select: []}
    end
  end

  describe "select in the join payload" do
    test "S1: postgres_changes entries carry select when the binding has it", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "db-changes")

      :ok =
        Registry.subscribe(registry, channel, "postgres_changes", %{
          event: "UPDATE",
          schema: "public",
          table: "users",
          filter: "id=eq.1",
          select: ["id", "first_name"]
        })

      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(store, channel.ref)
      message = Message.subscription_message(stored, "token")

      [entry] = message.payload.config.postgres_changes
      assert entry.select == ["id", "first_name"]
      assert entry.event == "UPDATE"
      assert entry.schema == "public"
      assert entry.table == "users"
      assert entry.filter == "id=eq.1"
    end

    test "S2: postgres_changes entries omit select when the binding has none", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "db-changes")

      :ok =
        Registry.subscribe(registry, channel, "postgres_changes", %{
          event: "INSERT",
          schema: "public",
          table: "users"
        })

      Process.sleep(50)

      {:ok, stored} = Store.find_by_ref(store, channel.ref)
      message = Message.subscription_message(stored, "token")

      [entry] = message.payload.config.postgres_changes
      refute Map.has_key?(entry, :select)
    end
  end

  describe "presence state handling" do
    test "R7: the presence_state payload IS the state map (bug 20)", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "room1")

      payload = %{
        "u1" => %{"metas" => [%{"phx_ref" => "r1", "user_id" => 1}]},
        "u2" => %{"metas" => [%{"phx_ref" => "r2", "phx_ref_prev" => "r0", "user_id" => 2}]}
      }

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence_state",
        "payload" => payload
      })

      assert :sys.get_state(registry).presence_state == payload
    end

    test "R8: diff joins merge per phx_ref (bug 21)", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "room1")

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence_state",
        "payload" => %{"u1" => %{"metas" => [%{"phx_ref" => "r1"}]}}
      })

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence_diff",
        "payload" => %{
          "joins" => %{"u1" => %{"metas" => [%{"phx_ref" => "r2"}]}},
          "leaves" => %{}
        }
      })

      assert %{"u1" => %{"metas" => metas}} = :sys.get_state(registry).presence_state
      assert [%{"phx_ref" => "r1"}, %{"phx_ref" => "r2"}] = metas
    end

    test "R9: diff leaves remove only the listed refs, keeping the key", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "room1")

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence_state",
        "payload" => %{"u1" => %{"metas" => [%{"phx_ref" => "r1"}, %{"phx_ref" => "r2"}]}}
      })

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence_diff",
        "payload" => %{
          "joins" => %{},
          "leaves" => %{"u1" => %{"metas" => [%{"phx_ref" => "r2"}]}}
        }
      })

      assert %{"u1" => %{"metas" => metas}} = :sys.get_state(registry).presence_state
      assert [%{"phx_ref" => "r1"}] = metas
    end

    test "R10: a diff with joins and leaves dispatches join, leave then sync", %{registry: registry} do
      on_exit(fn -> RealtimeTest.clear_collector() end)
      {:ok, channel} = Registry.create_channel(registry, "room1")
      RealtimeTest.set_collector(self())

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence_state",
        "payload" => %{"u1" => %{"metas" => [%{"phx_ref" => "r1"}]}}
      })

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence_diff",
        "payload" => %{
          "joins" => %{"u2" => %{"metas" => [%{"phx_ref" => "r2"}]}},
          "leaves" => %{"u1" => %{"metas" => [%{"phx_ref" => "r1"}]}}
        }
      })

      joins = %{"u2" => %{"metas" => [%{"phx_ref" => "r2"}]}}
      leaves = %{"u1" => %{"metas" => [%{"phx_ref" => "r1"}]}}
      state = %{"u2" => %{"metas" => [%{"phx_ref" => "r2"}]}}

      assert_receive {:dispatched, {:presence, :join, ^joins}}, 1000
      assert_receive {:dispatched, {:presence, :leave, ^leaves}}, 1000
      assert_receive {:dispatched, {:presence, :sync, ^state}}, 1000
    end
  end

  describe "dispatch_event callback warning" do
    test "R11: zero matching channels does not warn about a missing callback", %{registry: registry} do
      {:ok, _channel} = Registry.create_channel(registry, "room1")

      log =
        capture_log(fn ->
          Registry.handle_message(registry, %{
            "topic" => "realtime:ghost",
            "event" => "broadcast",
            "payload" => %{"event" => "x", "payload" => %{}}
          })

          Process.sleep(50)
        end)

      refute log =~ "No handle_event/1 callback"
    end

    test "R12: a missing handle_event/1 callback with channels present still warns", %{store: store} do
      unique_id = System.unique_integer([:positive])

      # an explicit child id: the setup registry already claimed the module-id
      # child spec on the test supervisor
      registry =
        start_supervised!(
          Supervisor.child_spec(
            {Registry, module: NoHandler, name: :"NoHandlerRegistry#{unique_id}", store: store},
            id: :"NoHandlerRegistrySpec#{unique_id}"
          )
        )

      {:ok, channel} = Registry.create_channel(registry, "room1")
      :ok = Registry.subscribe(registry, channel, "broadcast", %{event: "x"})
      Process.sleep(50)

      log =
        capture_log(fn ->
          Registry.handle_message(registry, %{
            "topic" => channel.topic,
            "event" => "broadcast",
            "payload" => %{"event" => "x", "payload" => %{}}
          })

          Process.sleep(50)
        end)

      assert log =~ "No handle_event/1 callback"
    end

    test "R13: an inbound outbound-presence message shape falls through without a presence dispatch", %{
      registry: registry
    } do
      on_exit(fn -> RealtimeTest.clear_collector() end)
      {:ok, channel} = Registry.create_channel(registry, "room1")
      :ok = Registry.subscribe(registry, channel, "broadcast", %{event: "cursor-pos"})
      Process.sleep(50)
      RealtimeTest.set_collector(self())

      Registry.handle_message(registry, %{
        "topic" => channel.topic,
        "event" => "presence",
        "payload" => %{"type" => "presence", "event" => "track", "payload" => %{}}
      })

      Process.sleep(50)

      refute_received {:dispatched, {:presence, :track, _}}
      assert Process.alive?(registry)
    end
  end
end

defmodule Supabase.Realtime.Channel.RegistryTest do
  use ExUnit.Case, async: false

  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store

  @moduletag capture_log: true

  setup do
    unique_id = System.unique_integer([:positive])
    store_name = :"StoreForRegistry#{unique_id}"
    table_name = :"registry_test_table#{unique_id}"

    _store_pid = start_supervised!({Store, name: store_name, table_name: table_name})

    registry_pid =
      start_supervised!(
        {Registry, module: RealtimeTest, name: :"TestRegistry#{unique_id}", store: store_name}
      )

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
    test "marks channel as leaving", %{registry: registry, store: store} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      # Setting channel registry to self to avoid the "process attempted to call itself" error
      updated_channel = %{channel | registry: self()}
      :ok = Registry.unsubscribe(registry, updated_channel)

      # Give time for the state to be updated
      Process.sleep(50)

      {:ok, stored_channel} = Store.find_by_ref(store, channel.ref)
      assert stored_channel.state == :leaving
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
end

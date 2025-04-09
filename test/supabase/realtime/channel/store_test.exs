defmodule Supabase.Realtime.Channel.StoreTest do
  use ExUnit.Case, async: false

  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Channel.Store

  setup do
    # Start a store with unique name and table name for test isolation
    unique_id = System.unique_integer([:positive])
    store_name = :"Store#{unique_id}"
    table_name = :"supabase_realtime_channels_#{unique_id}"

    start_supervised!({Store, name: store_name, table_name: table_name})

    channel1 = Channel.new("test:channel1", self())
    channel2 = Channel.new("test:channel2", self())
    channel3 = %{Channel.new("test:channel3", self()) | join_ref: "join123"}

    {:ok,
     %{
       store: store_name,
       channel1: channel1,
       channel2: channel2,
       channel3: channel3
     }}
  end

  describe "initialization" do
    test "empty store has no channels", %{store: store} do
      # Use the store from setup which is already supervised
      assert Store.all(store) == []
    end
  end

  describe "insert/2" do
    test "inserts a channel", %{store: store, channel1: channel} do
      assert {:ok, ^channel} = Store.insert(store, channel)
      assert {:ok, ^channel} = Store.find_by_ref(store, channel.ref)
    end

    test "allows multiple channels", %{store: store, channel1: ch1, channel2: ch2} do
      Store.insert(store, ch1)
      Store.insert(store, ch2)

      channels = Store.all(store)
      assert length(channels) == 2
      assert Enum.any?(channels, &(&1.ref == ch1.ref))
      assert Enum.any?(channels, &(&1.ref == ch2.ref))
    end
  end

  describe "update/2" do
    test "updates an existing channel", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      updated_channel = %{channel | state: :joined}
      assert {:ok, ^updated_channel} = Store.update(store, updated_channel)
      assert {:ok, fetched} = Store.find_by_ref(store, channel.ref)
      assert fetched.state == :joined
    end
  end

  describe "update_state/3" do
    test "updates channel state", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      assert {:ok, updated} = Store.update_state(store, channel, :joining)
      assert updated.state == :joining

      assert {:ok, fetched} = Store.find_by_ref(store, channel.ref)
      assert fetched.state == :joining
    end
  end

  describe "update_join_ref/3" do
    test "updates join reference", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      assert {:ok, updated} = Store.update_join_ref(store, channel, "join456")
      assert updated.join_ref == "join456"

      assert {:ok, fetched} = Store.find_by_ref(store, channel.ref)
      assert fetched.join_ref == "join456"
    end
  end

  describe "add_binding/4" do
    test "adds binding to channel", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      type = "postgres_changes"
      filter = %{event: "INSERT", schema: "public", table: "users"}

      assert {:ok, updated} = Store.add_binding(store, channel, type, filter)
      assert Map.has_key?(updated.bindings, type)

      bindings = updated.bindings[type]
      assert length(bindings) == 1
      assert hd(bindings).filter == filter

      assert {:ok, fetched} = Store.find_by_ref(store, channel.ref)
      assert fetched.bindings == updated.bindings
    end

    test "adds multiple bindings of same type", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      type = "postgres_changes"
      filter1 = %{event: "INSERT", schema: "public", table: "users"}
      filter2 = %{event: "UPDATE", schema: "public", table: "users"}

      {:ok, updated1} = Store.add_binding(store, channel, type, filter1)
      {:ok, updated2} = Store.add_binding(store, updated1, type, filter2)

      bindings = updated2.bindings[type]
      assert length(bindings) == 2

      assert {:ok, fetched} = Store.find_by_ref(store, channel.ref)
      assert length(fetched.bindings[type]) == 2
    end
  end

  describe "remove_binding/3" do
    test "removes binding from channel", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      type = "postgres_changes"
      filter = %{event: "INSERT", schema: "public", table: "users"}

      {:ok, with_binding} = Store.add_binding(store, channel, type, filter)
      assert length(with_binding.bindings[type]) == 1

      {:ok, updated} = Store.remove_binding(store, with_binding, type, filter)
      assert updated.bindings[type] == []

      assert {:ok, fetched} = Store.find_by_ref(store, channel.ref)
      assert fetched.bindings[type] == []
    end
  end

  describe "remove/2" do
    test "removes channel from store", %{store: store, channel1: channel} do
      Store.insert(store, channel)
      assert {:ok, _} = Store.find_by_ref(store, channel.ref)

      assert :ok = Store.remove(store, channel)
      assert {:error, :not_found} = Store.find_by_ref(store, channel.ref)
    end
  end

  describe "find_by_ref/2" do
    test "finds channel by reference", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      assert {:ok, found} = Store.find_by_ref(store, channel.ref)
      assert found.ref == channel.ref
    end

    test "returns error when not found", %{store: store} do
      assert {:error, :not_found} = Store.find_by_ref(store, "nonexistent")
    end
  end

  describe "find_by_topic/2" do
    test "finds channel by topic", %{store: store, channel1: channel} do
      Store.insert(store, channel)

      assert {:ok, found} = Store.find_by_topic(store, channel.topic)
      assert found.topic == channel.topic
    end

    test "returns error when not found", %{store: store} do
      assert {:error, :not_found} = Store.find_by_topic(store, "nonexistent:topic")
    end
  end

  describe "find_by_join_ref/2" do
    test "finds channel by join reference", %{store: store, channel3: channel} do
      Store.insert(store, channel)

      assert {:ok, found} = Store.find_by_join_ref(store, channel.join_ref)
      assert found.join_ref == channel.join_ref
    end

    test "returns error when not found", %{store: store} do
      assert {:error, :not_found} = Store.find_by_join_ref(store, "nonexistent")
    end
  end

  describe "all/1" do
    test "returns all channels", %{store: store, channel1: ch1, channel2: ch2} do
      Store.insert(store, ch1)
      Store.insert(store, ch2)

      channels = Store.all(store)
      assert length(channels) == 2

      refs = Enum.map(channels, & &1.ref)
      assert ch1.ref in refs
      assert ch2.ref in refs
    end

    test "returns empty list when store is empty", %{store: store} do
      assert Store.all(store) == []
    end
  end

  describe "find_all_by_topic/2" do
    test "returns channels with matching topic", %{
      store: store,
      channel1: ch1,
      channel2: ch2,
      channel3: ch3
    } do
      # Create two channels with the same topic
      same_topic_ch1 = %{ch1 | topic: "same:topic"}
      same_topic_ch2 = %{ch2 | topic: "same:topic"}

      Store.insert(store, same_topic_ch1)
      Store.insert(store, same_topic_ch2)
      # Different topic
      Store.insert(store, ch3)

      channels = Store.find_all_by_topic(store, "same:topic")
      assert length(channels) == 2

      topics = Enum.map(channels, & &1.topic)
      assert Enum.all?(topics, &(&1 == "same:topic"))
    end

    test "returns empty list when no channels match topic", %{store: store} do
      assert Store.find_all_by_topic(store, "nonexistent:topic") == []
    end
  end
end

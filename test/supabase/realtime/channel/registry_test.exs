defmodule Supabase.Realtime.Channel.RegistryTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Channel.Registry

  @moduletag capture_log: true

  setup do
    {:ok, registry} = Registry.start_link(module: RealtimeTest, name: :test_registry)

    %{registry: registry}
  end

  describe "start_link/1" do
    test "starts the registry with the correct initial state" do
      {:ok, pid} = Registry.start_link(module: RealtimeTest)

      state = :sys.get_state(pid)

      assert state.module == RealtimeTest
      assert state.channels == %{}
      assert state.pending_events == []
      assert state.presence_state == %{}
    end

    test "fails if module option is missing" do
      assert_raise KeyError, fn ->
        Registry.start_link([])
      end
    end
  end

  describe "create_channel/3" do
    test "creates a new channel", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      state = :sys.get_state(registry)

      assert Map.has_key?(state.channels, channel.ref)
      stored_channel = Map.get(state.channels, channel.ref)
      assert stored_channel.topic == "realtime:my_topic"
    end

    test "normalizes topic names", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "public:users")

      state = :sys.get_state(registry)
      stored_channel = Map.get(state.channels, channel.ref)

      assert stored_channel.topic == "realtime:public:users"
    end

    test "returns existing channel if topic already exists", %{registry: registry} do
      {:ok, channel1} = Registry.create_channel(registry, "my_topic")
      {:ok, channel2} = Registry.create_channel(registry, "my_topic")

      assert channel1.ref == channel2.ref

      state = :sys.get_state(registry)
      assert map_size(state.channels) == 1
    end
  end

  describe "subscribe/4" do
    test "adds binding to channel", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")
      :ok = Registry.subscribe(registry, channel, "postgres_changes", %{event: "INSERT"})

      state = :sys.get_state(registry)
      stored_channel = Map.get(state.channels, channel.ref)

      assert map_size(stored_channel.bindings) == 1
      assert [binding] = Map.get(stored_channel.bindings, "postgres_changes")
      assert binding.type == "postgres_changes"
      assert binding.filter == %{event: "INSERT"}
    end

    test "returns error for non-existent channel", %{registry: registry} do
      non_existent_channel = %Channel{ref: "non_existent", topic: "fake_topic", client: self()}

      assert {:error, :channel_not_found} =
               Registry.subscribe(registry, non_existent_channel, "postgres_changes", %{})
    end
  end

  describe "unsubscribe/2" do
    test "marks channel as leaving", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")
      :ok = Registry.unsubscribe(registry, channel)

      state = :sys.get_state(registry)
      stored_channel = Map.get(state.channels, channel.ref)

      assert stored_channel.state == :leaving
    end

    test "returns error for non-existent channel", %{registry: registry} do
      non_existent_channel = %Channel{ref: "non_existent", topic: "fake_topic", client: self()}

      assert {:error, :channel_not_found} = Registry.unsubscribe(registry, non_existent_channel)
    end
  end

  describe "remove_all_channels/1" do
    test "marks all channels as leaving", %{registry: registry} do
      {:ok, channel1} = Registry.create_channel(registry, "topic1")
      {:ok, channel2} = Registry.create_channel(registry, "topic2")

      :ok = Registry.remove_all_channels(registry)

      state = :sys.get_state(registry)

      assert Map.get(state.channels, channel1.ref).state == :leaving
      assert Map.get(state.channels, channel2.ref).state == :leaving
    end
  end

  describe "update_join_ref/3" do
    test "updates join_ref for channel", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      Registry.update_join_ref(registry, channel, "new_join_ref")

      Process.sleep(10)

      state = :sys.get_state(registry)
      stored_channel = Map.get(state.channels, channel.ref)

      assert stored_channel.join_ref == "new_join_ref"
    end
  end

  describe "update_channel_state/3" do
    test "updates channel state", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      Registry.update_channel_state(registry, channel, :joined)

      Process.sleep(10)

      state = :sys.get_state(registry)
      stored_channel = Map.get(state.channels, channel.ref)

      assert stored_channel.state == :joined
    end
  end

  describe "handle_message/2" do
    test "processes Postgres INSERT event", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "public:users")
      Registry.subscribe(registry, channel, "postgres_changes", %{event: "INSERT"})

      message = %{
        topic: "realtime:public:users",
        event: "INSERT",
        payload: %{id: 1, name: "Test User"}
      }

      Registry.handle_message(registry, message)
    end

    test "processes broadcast event", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "public:users")
      Registry.subscribe(registry, channel, "broadcast", %{event: "new_message"})

      message = %{
        topic: "realtime:public:users",
        event: "new_message",
        payload: %{text: "Hello world"}
      }

      Registry.handle_message(registry, message)
    end

    test "processes phx_reply for successful join", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      message = %{
        topic: "realtime:my_topic",
        event: "phx_reply",
        payload: %{"status" => "ok"}
      }

      Registry.handle_message(registry, message)

      state = :sys.get_state(registry)
      stored_channel = Map.get(state.channels, channel.ref)

      assert stored_channel.state == :joined
    end

    test "processes phx_reply for failed join", %{registry: registry} do
      {:ok, channel} = Registry.create_channel(registry, "my_topic")

      message = %{
        topic: "realtime:my_topic",
        event: "phx_reply",
        payload: %{"status" => "error"}
      }

      Registry.handle_message(registry, message)

      state = :sys.get_state(registry)
      stored_channel = Map.get(state.channels, channel.ref)

      assert stored_channel.state == :errored
    end
  end
end

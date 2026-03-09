defmodule Supabase.Realtime.PushBufferTest do
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

    unique_id = System.unique_integer([:positive])
    registry_name = :"Registry#{unique_id}"
    store_name = :"Store#{unique_id}"
    conn_name = :"Connection#{unique_id}"
    table_name = :"table#{unique_id}"

    start_supervised!({Store, name: store_name, table_name: table_name})
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name, connection: conn_name})

    {:ok, channel} = Registry.create_channel(registry_name, "test_topic")

    {:ok,
     %{
       registry: registry_name,
       store: store_name,
       channel: channel,
       conn_name: conn_name
     }}
  end

  describe "push buffer" do
    test "buffers messages when channel is joining", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: @mock_client
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      # Force open and channel to joining
      stream_ref = make_ref()
      socket = self()

      :sys.replace_state(pid, fn state ->
        %{state | status: :open, socket: socket, stream_ref: stream_ref}
      end)

      Store.update_state(ctx.store, ctx.channel, :joining)

      payload = %{event: "broadcast", payload: %{data: "buffered"}}
      assert :ok = Connection.send_message(pid, ctx.channel, payload)

      state = :sys.get_state(pid)
      assert Map.has_key?(state.push_buffers, ctx.channel.topic)
      assert :queue.len(Map.get(state.push_buffers, ctx.channel.topic)) == 1
    end

    test "flushes push buffer on channel_joined cast", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: @mock_client
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      stream_ref = make_ref()
      socket = self()

      :sys.replace_state(pid, fn state ->
        %{state | status: :open, socket: socket, stream_ref: stream_ref}
      end)

      # Pre-fill push buffer
      topic = ctx.channel.topic

      :sys.replace_state(pid, fn state ->
        queue = :queue.from_list([{ctx.channel, %{event: "broadcast", payload: %{data: "test"}}}])
        %{state | push_buffers: Map.put(state.push_buffers, topic, queue)}
      end)

      # Trigger channel_joined
      GenServer.cast(pid, {:channel_joined, topic})
      Process.sleep(100)

      state = :sys.get_state(pid)
      refute Map.has_key?(state.push_buffers, topic)
    end
  end
end

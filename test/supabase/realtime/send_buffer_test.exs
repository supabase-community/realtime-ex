defmodule Supabase.Realtime.SendBufferTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection

  @moduletag capture_log: true

  defmodule MockClient do
    @moduledoc false
    def get_client do
      {:ok,
       %Supabase.Client{
         api_key: "mock_api_key",
         realtime_url: "https://example.com",
         base_url: "https://example.com",
         access_token: "mock_token"
       }}
    end
  end

  setup do
    set_mimic_global()

    unique_id = System.unique_integer([:positive])
    registry_name = :"Registry#{unique_id}"
    store_name = :"Store#{unique_id}"
    conn_name = :"Connection#{unique_id}"
    table_name = :"table#{unique_id}"

    start_supervised!({Store, name: store_name, table_name: table_name})
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name})

    {:ok, channel} = Registry.create_channel(registry_name, "test_topic")

    {:ok,
     %{
       registry: registry_name,
       store: store_name,
       channel: channel,
       conn_name: conn_name
     }}
  end

  describe "send buffer" do
    test "buffers messages when disconnected and returns :ok", ctx do
      stub(:gun, :open, fn _, _, _ -> {:error, :not_started} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: MockClient,
        reconnect_after_ms: fn _ -> to_timeout(hour: 1) end
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      :sys.replace_state(pid, fn state -> %{state | status: :closed, socket: nil} end)

      payload = %{event: "broadcast", payload: %{data: "test"}}
      assert :ok = Connection.send_message(pid, ctx.channel, payload)

      state = :sys.get_state(pid)
      assert state.send_buffer_size == 1
      assert :queue.len(state.send_buffer) == 1
    end

    test "drops oldest when buffer exceeds max size", ctx do
      stub(:gun, :open, fn _, _, _ -> {:error, :not_started} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: MockClient,
        reconnect_after_ms: fn _ -> to_timeout(hour: 1) end
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      :sys.replace_state(pid, fn state -> %{state | status: :closed, socket: nil} end)

      # Fill buffer beyond max (100)
      for i <- 1..105 do
        payload = %{event: "broadcast", payload: %{idx: i}}
        Connection.send_message(pid, ctx.channel, payload)
      end

      state = :sys.get_state(pid)
      assert state.send_buffer_size == 100

      # Verify oldest were dropped - first item should be idx 6
      {{:value, {_ch, payload}}, _} = :queue.out(state.send_buffer)
      assert payload.payload.idx == 6
    end

    test "flushes buffer on websocket upgrade", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: MockClient
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      # Force disconnected state with buffered messages
      stream_ref = make_ref()
      socket = self()

      :sys.replace_state(pid, fn state ->
        buffer =
          Enum.reduce(1..3, :queue.new(), fn i, q ->
            :queue.in({ctx.channel, %{event: "broadcast", payload: %{idx: i}}}, q)
          end)

        %{state | status: :closed, socket: socket, stream_ref: stream_ref, send_buffer: buffer, send_buffer_size: 3}
      end)

      # Simulate gun_upgrade message
      send(pid, {:gun_upgrade, socket, stream_ref, ["websocket"], []})
      Process.sleep(100)

      state = :sys.get_state(pid)
      assert state.send_buffer_size == 0
      assert :queue.is_empty(state.send_buffer)
      assert state.status == :open
    end
  end
end

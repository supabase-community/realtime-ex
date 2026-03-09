defmodule Supabase.Realtime.ClientIntegrationTest do
  use ExUnit.Case, async: false
  use Mimic

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection
  alias Supabase.Realtime.Error

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
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name})

    {:ok,
     %{
       registry: registry_name,
       store: store_name,
       conn_name: conn_name
     }}
  end

  describe "Connection with %Supabase.Client{} struct" do
    test "starts with a client struct directly", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: @mock_client
      ]

      assert {:ok, pid} = Connection.start_link(opts)
      state = :sys.get_state(pid)
      assert %Supabase.Client{} = state.client
      assert state.client.api_key == "mock_api_key"
      assert state.client.access_token == "mock_token"
    end

    test "uses client struct for connection without calling get_client/0", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: @mock_client
      ]

      assert {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      # Connection should be attempting to connect
      state = :sys.get_state(pid)
      assert state.status == :connecting
    end
  end

  describe "Error.to_supabase_error/1" do
    test "converts realtime error to supabase error" do
      error = Error.new(:not_connected, "WebSocket is not connected")
      supabase_error = Error.to_supabase_error(error)

      assert %Supabase.Error{} = supabase_error
      assert supabase_error.code == :not_connected
      assert supabase_error.message == "WebSocket is not connected"
      assert supabase_error.service == :realtime
      assert supabase_error.metadata == %{}
    end

    test "preserves context as metadata" do
      error = Error.new(:channel_error, "Failed to join", %{topic: "realtime:test"})
      supabase_error = Error.to_supabase_error(error)

      assert supabase_error.metadata == %{topic: "realtime:test"}
    end
  end
end

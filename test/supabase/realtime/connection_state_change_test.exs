defmodule Supabase.Realtime.ConnectionStateChangeTest do
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
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name, connection: conn_name})

    {:ok, %{registry: registry_name, store: store_name, conn_name: conn_name}}
  end

  test "stores custom_params in state", ctx do
    stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
    stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
    stub(:gun, :ws_send, fn _, _, _ -> :ok end)

    opts = [
      name: ctx.conn_name,
      registry: ctx.registry,
      store: ctx.store,
      client: MockClient,
      params: %{log_level: "debug"}
    ]

    {:ok, pid} = Connection.start_link(opts)
    Process.sleep(50)

    state = :sys.get_state(pid)
    assert state.custom_params == %{log_level: "debug"}
  end

  test "dispatches connection state change via registry", ctx do
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

    # Simulate gun_upgrade to transition to :open
    stream_ref = make_ref()
    socket = self()

    :sys.replace_state(pid, fn state ->
      %{state | socket: socket, stream_ref: stream_ref, status: :connecting}
    end)

    send(pid, {:gun_upgrade, socket, stream_ref, ["websocket"], []})
    Process.sleep(100)

    state = :sys.get_state(pid)
    assert state.status == :open
  end
end

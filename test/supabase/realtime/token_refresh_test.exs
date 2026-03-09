defmodule Supabase.Realtime.TokenRefreshTest do
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
         access_token: "default_token"
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

    {:ok,
     %{
       registry: registry_name,
       store: store_name,
       conn_name: conn_name
     }}
  end

  describe "dynamic token refresh" do
    test "accepts access_token_fn as a capture function", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      token_fn = fn -> {:ok, "refreshed_token"} end

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: MockClient,
        access_token_fn: token_fn
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert is_function(state.access_token_fn, 0)
    end

    test "accepts access_token_fn as MFA tuple", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: MockClient,
        access_token_fn: {__MODULE__, :get_token, []}
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.access_token_fn == {__MODULE__, :get_token, []}
    end

    test "stores http_fallback option", ctx do
      stub(:gun, :open, fn _, _, _ -> {:ok, self()} end)
      stub(:gun, :ws_upgrade, fn _, _, _ -> make_ref() end)
      stub(:gun, :ws_send, fn _, _, _ -> :ok end)

      opts = [
        name: ctx.conn_name,
        registry: ctx.registry,
        store: ctx.store,
        client: MockClient,
        http_fallback: true
      ]

      {:ok, pid} = Connection.start_link(opts)
      Process.sleep(50)

      state = :sys.get_state(pid)
      assert state.http_fallback == true
    end
  end

  def get_token, do: {:ok, "mfa_token"}
end

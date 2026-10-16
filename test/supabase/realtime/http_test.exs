defmodule Supabase.Realtime.HTTPTest do
  # mocking global modules (Supabase.Fetcher and :gun)
  use ExUnit.Case, async: false
  use Mimic

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Connection
  alias Supabase.Realtime.HTTP
  alias Supabase.Realtime.Message

  @moduletag capture_log: true

  setup do
    set_mimic_global()

    test = self()

    stub(Supabase.Fetcher, :request, fn request ->
      send(test, {:captured_request, request})
      {:ok, %Supabase.Fetcher.Response{status: 200, headers: [], body: "{}"}}
    end)

    %{client: Support.Client.client()}
  end

  defp decoded_messages do
    assert_received {:captured_request, request}
    [message] = request.body |> IO.iodata_to_binary() |> JSON.decode!() |> Map.get("messages")
    message
  end

  test "H1: strips the realtime: topic prefix from the wire message", %{client: client} do
    assert :ok = HTTP.broadcast(client, "tok", "realtime:room:lobby", "new_msg", %{body: "hi"})

    assert decoded_messages()["topic"] == "room:lobby"
  end

  test "H2: sends private: false by default", %{client: client} do
    assert :ok = HTTP.broadcast(client, "tok", "realtime:room:lobby", "new_msg", %{body: "hi"})

    assert decoded_messages()["private"] == false
  end

  test "H3: sends private: true when opted in", %{client: client} do
    assert :ok =
             HTTP.broadcast(client, "tok", "realtime:room:lobby", "new_msg", %{body: "hi"}, private: true)

    assert decoded_messages()["private"] == true
  end

  test "H4: topics without the prefix pass through unchanged", %{client: client} do
    assert :ok = HTTP.broadcast(client, "tok", "room:lobby", "new_msg", %{body: "hi"})

    assert decoded_messages()["topic"] == "room:lobby"
  end

  test "H5: posts to /api/broadcast off the realtime url with the Bearer token", %{client: client} do
    assert :ok = HTTP.broadcast(client, "tok", "realtime:room:lobby", "new_msg", %{body: "hi"})

    assert_received {:captured_request, request}
    assert request.method == :post
    assert request.url.path =~ "/api/broadcast"
    assert List.keyfind(request.headers, "authorization", 0) == {"authorization", "Bearer tok"}
  end

  test "H6: http fallback from the Connection sends the sub-topic and private flag", %{client: client} do
    unique_id = System.unique_integer([:positive])
    store_name = :"Store#{unique_id}"
    registry_name = :"Registry#{unique_id}"
    conn_name = :"Connection#{unique_id}"

    start_supervised!({Store, name: store_name})
    start_supervised!({Registry, module: RealtimeTest, name: registry_name, store: store_name})

    stub(:gun, :open, fn _, _, _ -> {:error, :econnrefused} end)

    conn =
      start_supervised!(
        {Connection,
         name: conn_name,
         registry: registry_name,
         store: store_name,
         client: client,
         http_fallback: true,
         reconnect_after_ms: fn _ -> 60_000 end}
      )

    Process.sleep(30)

    {:ok, channel} = Registry.create_channel(registry_name, "private:room", private: true)
    payload = Message.broadcast_message(channel, "new_msg", %{body: "hi"})

    assert :ok = Connection.send_message(conn, channel, payload)

    message = decoded_messages()
    assert message["topic"] == "private:room"
    assert message["private"] == true
    assert message["event"] == "new_msg"
    assert message["payload"] == %{"body" => "hi"}
  end
end

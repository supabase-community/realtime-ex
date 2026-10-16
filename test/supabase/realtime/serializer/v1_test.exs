defmodule Supabase.Realtime.Serializer.V1Test do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Message
  alias Supabase.Realtime.Serializer.V1

  describe "encode/2" do
    test "encodes a message map as a JSON object text frame" do
      message = %{topic: "realtime:public", event: "INSERT", payload: %{"a" => 1}, ref: "1", join_ref: "7"}

      assert {:ok, {:text, json}} = V1.encode(message, [])

      # order-independent: the encoder's map key order is unspecified
      assert JSON.decode!(json) == %{
               "topic" => "realtime:public",
               "event" => "INSERT",
               "payload" => %{"a" => 1},
               "ref" => "1",
               "join_ref" => "7"
             }
    end

    test "extra message keys pass through untouched" do
      message = %{topic: "t", event: "e", payload: %{}, ref: "1", custom: %{nested: true}}

      assert {:ok, {:text, json}} = V1.encode(message, [])
      assert JSON.decode!(json)["custom"] == %{"nested" => true}
    end

    test "returns {:error, {:encode_failed, reason}} for unencodable terms" do
      assert {:error, {:encode_failed, _reason}} = V1.encode(%{topic: "t", event: "e", payload: self()}, [])
    end
  end

  describe "decode/2" do
    test "decodes a JSON object text frame into a string-keyed map" do
      assert {:ok, %{"topic" => "t", "event" => "e", "payload" => %{}, "ref" => "1"}} =
               V1.decode({:text, ~s({"topic":"t","event":"e","payload":{},"ref":"1"})}, [])
    end

    test "returns {:error, {:invalid_json, reason}} for invalid JSON" do
      assert {:error, {:invalid_json, _reason}} = V1.decode({:text, "not json"}, [])
    end

    test "rejects a non-map JSON frame" do
      assert {:error, {:unexpected_text_frame, [1, 2]}} = V1.decode({:text, "[1,2]"}, [])
    end

    test "rejects binary frames" do
      assert {:error, {:unexpected_frame, :binary}} = V1.decode({:binary, <<4, 1, 2>>}, [])
    end
  end

  test "round trip: the decoded encoded frame equals the original payload" do
    message = %{topic: "room", event: "broadcast", payload: %{"x" => 1}, ref: "42"}

    {:ok, {:text, json}} = V1.encode(message, [])
    assert {:ok, decoded} = V1.decode({:text, json}, [])

    assert decoded["topic"] == "room"
    assert decoded["event"] == "broadcast"
    assert decoded["payload"] == %{"x" => 1}
    assert decoded["ref"] == "42"
  end

  # The documented vsn 1.0.0 shape, order-independent: atom keys become
  # strings and the exact key set is preserved (the encoder's key order is
  # unspecified, so the JSON string is asserted by content, not bytes).
  test "Message.encode/1 keeps the documented vsn 1.0.0 JSON content" do
    assert {:ok, json} = Message.encode(%{topic: "realtime:public", event: "INSERT", payload: %{}, ref: "1"})

    assert JSON.decode!(json) == %{
             "topic" => "realtime:public",
             "event" => "INSERT",
             "payload" => %{},
             "ref" => "1"
           }
  end
end

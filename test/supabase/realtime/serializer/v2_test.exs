defmodule Supabase.Realtime.Serializer.V2Test do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Serializer.V2

  # The worked example from the spec (section 4). JSON object key order is not
  # part of the protocol and varies with the OTP map implementation, so the
  # payload bytes come from the same encoder the serializer uses rather than a
  # hardcoded literal.
  @worked_message %{
    topic: "realtime:sala",
    event: "broadcast",
    payload: %{type: "broadcast", event: "posição", payload: %{x: 1, y: 2}},
    ref: "42",
    join_ref: "7"
  }

  @worked_frame <<3, 1, 2, 13, 9, 0, 1>> <>
                  "7" <> "42" <> "realtime:sala" <> "posição" <> "" <> JSON.encode!(%{x: 1, y: 2})

  describe "encode/2 - kind 3 (userBroadcastPush)" do
    test "encodes the worked example as an exact 45-byte binary frame" do
      assert {:ok, {:binary, frame}} = V2.encode(@worked_message, [])
      assert frame == @worked_frame
      assert byte_size(frame) == 45
    end

    test "length bytes are UTF-8 byte counts, not character counts" do
      {:ok, {:binary, frame}} = V2.encode(@worked_message, [])

      # byte 4 is the user_event length: "posição" is 9 bytes (7 chars)
      assert binary_part(frame, 4, 1) == <<9>>
      assert String.length("posição") == 7
    end

    test "raw binary user payload goes out verbatim with encoding byte 0" do
      message = %{
        topic: "realtime:sala",
        event: "broadcast",
        payload: %{type: "broadcast", event: "e", payload: <<0xFF, 0x00, 0xAA>>},
        ref: "42",
        join_ref: "7"
      }

      expected =
        <<3, 1, 2, 13, 1, 0, 0>> <>
          "7" <> "42" <> "realtime:sala" <> "e" <> "" <> <<0xFF, 0x00, 0xAA>>

      assert {:ok, {:binary, frame}} = V2.encode(message, [])
      assert frame == expected
    end

    test "nil user payload goes through the JSON path as {}" do
      message = %{
        topic: "realtime:sala",
        event: "broadcast",
        payload: %{type: "broadcast", event: "e", payload: nil},
        ref: "42",
        join_ref: "7"
      }

      expected = <<3, 1, 2, 13, 1, 0, 1>> <> "7" <> "42" <> "realtime:sala" <> "e" <> "" <> "{}"

      assert {:ok, {:binary, frame}} = V2.encode(message, [])
      assert frame == expected
    end

    test "missing join_ref and ref serialize as zero-length fields" do
      message = %{
        topic: "realtime:sala",
        event: "broadcast",
        payload: %{type: "broadcast", event: "e", payload: %{}}
      }

      expected = <<3, 0, 0, 13, 1, 0, 1>> <> "realtime:sala" <> "e" <> "" <> "{}"

      assert {:ok, {:binary, frame}} = V2.encode(message, [])
      assert frame == expected
    end

    test "rejects a 256-byte join_ref" do
      message = %{topic: "t", event: "broadcast", payload: %{event: "e"}, join_ref: String.duplicate("a", 256)}

      assert {:error, {:field_too_long, :join_ref, 256}} = V2.encode(message, [])
    end

    test "rejects a 256-byte ref" do
      message = %{topic: "t", event: "broadcast", payload: %{event: "e"}, ref: String.duplicate("a", 256)}

      assert {:error, {:field_too_long, :ref, 256}} = V2.encode(message, [])
    end

    test "rejects a 256-byte topic" do
      message = %{topic: String.duplicate("a", 256), event: "broadcast", payload: %{event: "e"}}

      assert {:error, {:field_too_long, :topic, 256}} = V2.encode(message, [])
    end

    test "rejects a 256-byte user event" do
      message = %{topic: "t", event: "broadcast", payload: %{event: String.duplicate("a", 256)}}

      assert {:error, {:field_too_long, :user_event, 256}} = V2.encode(message, [])
    end

    test "rejects 256 bytes of metadata" do
      message = %{
        topic: "t",
        event: "broadcast",
        payload: %{event: "e", k: String.duplicate("m", 248)}
      }

      # {"k":"<248 m's>"} is exactly 256 bytes
      assert {:error, {:field_too_long, :metadata, 256}} = V2.encode(message, allowed_metadata_keys: [:k])
    end

    test "guards count bytes, not characters" do
      # 130 two-byte codepoints = 260 bytes
      topic = String.duplicate("é", 130)
      assert byte_size(topic) == 260
      assert String.length(topic) == 130

      message = %{topic: topic, event: "broadcast", payload: %{event: "e"}}

      assert {:error, {:field_too_long, :topic, 260}} = V2.encode(message, [])
    end

    test "allowed_metadata_keys pick payload keys into the metadata section" do
      message = %{
        topic: "realtime:sala",
        event: "broadcast",
        payload: %{event: "e", payload: %{}, user_id: 42}
      }

      assert {:ok, {:binary, frame}} = V2.encode(message, allowed_metadata_keys: [:user_id])

      # metadata_size is byte 5; the section holds the picked keys as JSON
      assert binary_part(frame, 5, 1) == <<byte_size(~s({"user_id":42}))>>

      # 7 header + 13 topic + 1 user_event + 14 metadata + 2 user payload
      assert byte_size(frame) == 7 + 13 + 1 + 14 + 2
      assert frame =~ ~s({"user_id":42})
    end

    test "metadata keys absent from the payload produce an empty section" do
      message = %{topic: "realtime:sala", event: "broadcast", payload: %{event: "e", payload: %{}}}

      assert {:ok, {:binary, frame}} = V2.encode(message, allowed_metadata_keys: [:user_id])
      assert binary_part(frame, 5, 1) == <<0>>
    end

    test "default opts produce an empty metadata section" do
      {:ok, {:binary, frame}} = V2.encode(@worked_message, [])
      assert binary_part(frame, 5, 1) == <<0>>
    end

    test "a broadcast payload without a binary event key falls to the JSON array path" do
      message = %{topic: "t", event: "broadcast", payload: %{type: "broadcast"}, ref: "1"}

      assert {:ok, {:text, json}} = V2.encode(message, [])
      assert JSON.decode!(json) == [nil, "1", "t", "broadcast", %{"type" => "broadcast"}]
    end

    test "a broadcast event with a non-map payload falls to the JSON array path" do
      message = %{topic: "t", event: "broadcast", payload: "raw", ref: "1"}

      assert {:ok, {:text, json}} = V2.encode(message, [])
      assert JSON.decode!(json) == [nil, "1", "t", "broadcast", "raw"]
    end
  end

  describe "encode/2 - JSON array (text)" do
    test "encodes a non-broadcast message as an exact array string" do
      message = %{topic: "phoenix", event: "heartbeat", payload: %{}, ref: "10"}

      assert {:ok, {:text, ~s([null,"10","phoenix","heartbeat",{}])}} = V2.encode(message, [])
    end

    test "present join_ref and ref are serialized as array elements" do
      message = %{
        topic: "phoenix",
        event: "phx_reply",
        payload: %{"status" => "ok", "response" => %{}},
        ref: "42",
        join_ref: "7"
      }

      # map key order under the native JSON encoder is lexicographic here
      assert {:ok, {:text, ~s(["7","42","phoenix","phx_reply",{"response":{},"status":"ok"}])}} =
               V2.encode(message, [])
    end

    test "returns {:error, {:encode_failed, reason}} for unencodable terms" do
      message = %{topic: "t", event: "e", payload: self(), ref: "1"}

      assert {:error, {:encode_failed, _reason}} = V2.encode(message, [])
    end
  end

  describe "decode/2 - kind 4 (userBroadcast)" do
    test "decodes the worked example, with no meta key when metadata is empty" do
      frame = <<4, 13, 9, 0, 1>> <> "realtime:sala" <> "posição" <> "" <> ~s({"x":1,"y":2})

      assert {:ok,
              %{
                "join_ref" => nil,
                "ref" => nil,
                "topic" => "realtime:sala",
                "event" => "broadcast",
                "payload" => %{
                  "type" => "broadcast",
                  "event" => "posição",
                  "payload" => %{"x" => 1, "y" => 2}
                }
              }} = V2.decode({:binary, frame}, [])
    end

    test "raw payload (encoding 0) is returned untouched" do
      frame = <<4, 13, 1, 0, 0>> <> "realtime:sala" <> "e" <> <<0xFF, 0x00, 0xAA>>

      assert {:ok, %{"payload" => %{"payload" => <<0xFF, 0x00, 0xAA>>}}} = V2.decode({:binary, frame}, [])
    end

    test "metadata is parsed and exposed under meta when present" do
      frame = <<4, 13, 1, 14, 1>> <> "realtime:sala" <> "e" <> ~s({"user_id":42}) <> ~s({"x":1})

      assert {:ok, %{"payload" => payload}} = V2.decode({:binary, frame}, [])
      assert payload["meta"] == %{"user_id" => 42}
    end

    test "returns {:error, {:invalid_payload, reason}} for invalid JSON payload bytes" do
      frame = <<4, 13, 1, 0, 1>> <> "realtime:sala" <> "e" <> "{bad"

      assert {:error, {:invalid_payload, _reason}} = V2.decode({:binary, frame}, [])
    end

    test "returns {:error, {:invalid_json, reason}} for invalid JSON metadata" do
      frame = <<4, 13, 1, 4, 1>> <> "realtime:sala" <> "e" <> "{bad" <> ~s({"x":1})

      assert {:error, {:invalid_json, _reason}} = V2.decode({:binary, frame}, [])
    end

    test "kinds other than 4 are unsupported" do
      for kind <- [0, 1, 2, 5] do
        assert {:error, {:unsupported_kind, ^kind}} = V2.decode({:binary, <<kind>>}, [])
      end

      assert {:error, {:unsupported_kind, 255}} = V2.decode({:binary, <<255, 1, 2>>}, [])
    end
  end

  describe "decode/2 - text (JSON array)" do
    test "decodes an array frame into the registry message shape" do
      data = ~s(["7","10","phoenix","phx_reply",{"status":"ok","response":{}}])

      assert {:ok,
              %{
                "join_ref" => "7",
                "ref" => "10",
                "topic" => "phoenix",
                "event" => "phx_reply",
                "payload" => %{"status" => "ok", "response" => %{}}
              }} = V2.decode({:text, data}, [])
    end

    test "tolerates trailing array elements" do
      data = ~s(["7","10","phoenix","phx_reply",{},"extra"])

      assert {:ok, %{"event" => "phx_reply"}} = V2.decode({:text, data}, [])
    end

    test "rejects a non-array JSON frame" do
      assert {:error, {:unexpected_text_frame, %{"topic" => "phoenix"}}} =
               V2.decode({:text, ~s({"topic":"phoenix"})}, [])
    end

    test "returns {:error, {:invalid_json, reason}} for invalid JSON" do
      assert {:error, {:invalid_json, _reason}} = V2.decode({:text, "not json"}, [])
    end
  end

  test "round trip: a kind-3 push decodes back through a server-shaped kind-4 frame" do
    {:ok, {:binary, encoded}} = V2.encode(@worked_message, [])

    # the server rebuilds the fields into a kind-4 frame (metadata empty)
    <<3, jr, rf, ts, es, ms, 1, _join_ref::binary-size(jr), _ref::binary-size(rf), topic::binary-size(ts),
      user_event::binary-size(es), metadata::binary-size(ms), user_payload::binary>> = encoded

    assert ms == 0

    server_frame = <<4, ts, es, ms, 1>> <> topic <> user_event <> metadata <> user_payload

    assert {:ok,
            %{
              "topic" => "realtime:sala",
              "event" => "broadcast",
              "payload" => %{"type" => "broadcast", "event" => "posição", "payload" => %{"x" => 1, "y" => 2}}
            }} = V2.decode({:binary, server_frame}, [])
  end
end

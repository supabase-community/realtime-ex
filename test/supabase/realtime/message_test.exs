defmodule Supabase.Realtime.MessageTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Message

  describe "subscription_message/2" do
    test "builds the flat postgres_changes server shape with uppercase events" do
      channel =
        "test:topic"
        |> Channel.new(self())
        |> Channel.add_binding("postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users",
          filter: "id=eq.1"
        })

      msg = Message.subscription_message(channel, nil)

      assert msg.topic == "realtime:test:topic"
      assert msg.event == "phx_join"

      assert msg.payload.config.postgres_changes == [
               %{event: "INSERT", schema: "public", table: "users", filter: "id=eq.1"}
             ]

      refute Map.has_key?(msg.payload, :access_token)
    end

    test "omits nil table and filter and passes unknown events through upcase" do
      channel =
        "test:topic"
        |> Channel.new(self())
        |> Channel.add_binding("postgres_changes", %{event: :all, schema: "public"})
        |> Channel.add_binding("postgres_changes", %{event: "write", schema: "public"})

      [first, second] = Message.subscription_message(channel, nil).payload.config.postgres_changes

      # bindings are stored newest-first; the wire list is emitted oldest-first
      assert first == %{event: "*", schema: "public"}
      assert second == %{event: "WRITE", schema: "public"}
    end

    test "presence is disabled by default and enabled by presence bindings" do
      channel = Channel.new("test:topic", self())
      assert Message.subscription_message(channel, nil).payload.config.presence == %{key: "", enabled: false}

      channel =
        "test:topic"
        |> Channel.new(self())
        |> Channel.add_binding("presence", %{})

      assert Message.subscription_message(channel, nil).payload.config.presence == %{key: "", enabled: true}
    end

    test "presence enabled respects a user-set value" do
      channel = Channel.new("test:topic", self(), presence: [key: "user:1", enabled: true])

      assert Message.subscription_message(channel, nil).payload.config.presence == %{
               key: "user:1",
               enabled: true
             }
    end

    test "includes access_token when token is non-nil" do
      channel = Channel.new("test:topic", self())

      msg = Message.subscription_message(channel, "jwt-token")

      assert msg.payload.access_token == "jwt-token"
    end
  end

  describe "encode/1" do
    test "encodes atom keys identically to string keys" do
      assert {:ok, encoded} = Message.encode(%{topic: "t", event: "e", payload: %{}, ref: "1"})
      assert encoded =~ ~s("topic":"t")
    end

    test "returns {:error, {:encode_failed, _}} for non-encodable terms" do
      assert {:error, {:encode_failed, _}} = Message.encode(%{pid: self()})
    end
  end

  describe "decode/1" do
    test "decodes a wire message" do
      assert {:ok, %{"topic" => "t", "event" => "e"}} = Message.decode(~s({"topic":"t","event":"e"}))
      assert {:error, _} = Message.decode("not json")
    end
  end
end

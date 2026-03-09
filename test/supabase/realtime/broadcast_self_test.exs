defmodule Supabase.Realtime.BroadcastSelfTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Message

  describe "broadcast.self configuration" do
    test "channel accepts broadcast: [self: true] option" do
      channel = Channel.new("test", self(), broadcast: [self: true])

      assert channel.params.config.broadcast.self == true
      assert channel.params.config.broadcast.ack == false
    end

    test "channel accepts broadcast: [self: true, ack: true] option" do
      channel = Channel.new("test", self(), broadcast: [self: true, ack: true])

      assert channel.params.config.broadcast.self == true
      assert channel.params.config.broadcast.ack == true
    end

    test "channel accepts presence: [key: \"user_id\"] option" do
      channel = Channel.new("test", self(), presence: [key: "user_id"])

      assert channel.params.config.presence.key == "user_id"
    end

    test "subscription message includes broadcast self config" do
      channel = Channel.new("test", self(), broadcast: [self: true])
      msg = Message.subscription_message(channel)

      assert msg.payload.config.broadcast.self == true
    end

    test "subscription message includes broadcast self as false by default" do
      channel = Channel.new("test", self())
      msg = Message.subscription_message(channel)

      assert msg.payload.config.broadcast.self == false
    end

    test "params option and broadcast option merge correctly" do
      channel =
        Channel.new("test", self(),
          params: %{config: %{private: true}},
          broadcast: [self: true]
        )

      assert channel.params.config.private == true
      assert channel.params.config.broadcast.self == true
    end
  end
end

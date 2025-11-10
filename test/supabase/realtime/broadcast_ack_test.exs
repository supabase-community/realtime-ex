defmodule Supabase.Realtime.BroadcastAckTest do
  use ExUnit.Case

  alias Supabase.Realtime
  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Message

  test "channel ack configuration" do
    registry_pid = self()

    # Default: ack disabled
    channel = Channel.new("test:channel", registry_pid)
    refute Channel.ack_enabled?(channel)

    # Enable ack
    opts = [params: %{config: %{broadcast: %{ack: true}}}]
    ack_channel = Channel.new("test:channel", registry_pid, opts)
    assert Channel.ack_enabled?(ack_channel)
  end

  test "broadcast message with ack includes ack_ref" do
    registry_pid = self()
    channel = Channel.new("test:channel", registry_pid)
    ack_ref = "ack:test123"

    message = Message.broadcast_message_with_ack(channel, "event", %{data: "test"}, ack_ref)

    assert message.ack_ref == ack_ref
    assert message.payload.event == "event"
  end

  test "wait_for_ack handles acknowledgment and timeout" do
    ack_ref = "ack:test123"
    parent = self()

    # Test acknowledgment
    spawn(fn ->
      Process.sleep(50)
      send(parent, {:ack_received, ack_ref})
    end)

    result = Realtime.wait_for_ack(ack_ref, timeout: 1000)
    assert {:ok, :acknowledged} == result

    # Test timeout
    timeout_result = Realtime.wait_for_ack("nonexistent", timeout: 100)
    assert {:error, :timeout} == timeout_result
  end
end

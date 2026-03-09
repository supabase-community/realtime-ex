defmodule Supabase.Realtime.ErrorTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Error

  test "creates error with new/3" do
    error = Error.new(:not_connected, "WebSocket is not connected")
    assert error.reason == :not_connected
    assert error.message == "WebSocket is not connected"
    assert error.context == %{}
  end

  test "creates error with context" do
    error = Error.new(:channel_error, "Failed to join", %{topic: "realtime:test"})
    assert error.reason == :channel_error
    assert error.context == %{topic: "realtime:test"}
  end

  test "implements Exception" do
    error = Error.new(:timeout, "Operation timed out")
    assert Exception.message(error) == "timeout: Operation timed out"
  end

  test "includes context in message when present" do
    error = Error.new(:timeout, "timed out", %{ref: "abc"})
    msg = Exception.message(error)
    assert msg =~ "timeout: timed out"
    assert msg =~ "ref: \"abc\""
  end

  test "can be raised" do
    assert_raise Error, fn ->
      raise Error.new(:test, "test error")
    end
  end
end

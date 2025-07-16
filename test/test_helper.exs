ExUnit.start()

# Initialize Mimic
Application.ensure_all_started(:mimic)
Mimic.copy(:gun)
Mimic.copy(Supabase.Realtime.Channel.Registry)

defmodule RealtimeTest do
  require Logger

  def handle_event(event) do
    Logger.info("Received event: #{inspect(event)}")
    send(self(), event)

    :ok
  end

  def send_message(channel, message) do
    Logger.debug("Mock sending message: #{inspect(message)} on channel #{channel.topic}")
    :ok
  end
end

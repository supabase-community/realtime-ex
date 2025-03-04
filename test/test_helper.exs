ExUnit.start()

defmodule RealtimeTest do
  require Logger

  def handle_event(event) do
    Logger.info("Received event: #{inspect(event)}")
    send(self(), event)

    :ok
  end
end

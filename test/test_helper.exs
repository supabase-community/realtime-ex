ExUnit.start()

# Initialize Mimic
Application.ensure_all_started(:mimic)
Mimic.copy(:gun)
Mimic.copy(Supabase.Realtime.Channel.Registry)

defmodule RealtimeTest do
  require Logger

  @collector_key {__MODULE__, :collector_pid}

  # Test event collector: when a collector pid is registered, dispatched
  # events are forwarded to it so tests can assert on them.
  def handle_event(event) do
    Logger.debug("Received event: #{inspect(event)}")

    case :persistent_term.get(@collector_key, nil) do
      nil -> :ok
      pid -> send(pid, {:dispatched, event})
    end

    :ok
  end

  def set_collector(pid), do: :persistent_term.put(@collector_key, pid)
  def clear_collector, do: :persistent_term.erase(@collector_key)
end

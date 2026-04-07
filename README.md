# Supabase Realtime

[![Hex.pm](https://img.shields.io/hexpm/v/supabase_realtime.svg)](https://hex.pm/packages/supabase_realtime)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/supabase_realtime)

Elixir client for Supabase Realtime. Provides OTP-powered connectivity for real-time database changes, broadcast messages, and presence features.

## Features

- **OTP Supervision**: Resilient connections with automatic recovery
- **Channel Subscriptions**: Patterns inspired by Phoenix Channels
- **Automatic Reconnection**: Exponential backoff reconnection strategy
- **Send and Push Buffers**: Messages buffered while disconnected, flushed on reconnect
- **HTTP Fallback**: Broadcast messages sent over HTTP when WebSocket is down
- **Token Refresh**: Dynamic token resolution with `access_token_fn`
- **Broadcast Acknowledgment**: Optional delivery confirmation for broadcasts
- **Broadcast Self**: Option to receive your own broadcast messages
- **Wildcard Events**: Subscribe to all events with `event: "*"` or `event: :all`
- **Presence Tracking**: Track and sync user presence across clients
- **Postgres Type Transforms**: Automatic conversion of database values to Elixir types

## Installation

Add `supabase_realtime` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:supabase_potion, "~> 0.7"},
    {:supabase_realtime, "~> 0.5.0"} # x-release-please-version
  ]
end
```

## Quick Start

### Create a Client

```elixir
{:ok, client} = Supabase.init_client(
  "https://your-project.supabase.co",
  "your-api-key"
)
```

### Define a Realtime Module

```elixir
defmodule MyApp.Realtime do
  use Supabase.Realtime

  def start_link(opts \\ []) do
    Supabase.Realtime.start_link(__MODULE__, opts)
  end

  @impl true
  def handle_event({:postgres_changes, :insert, payload}) do
    IO.inspect(payload, label: "New record")
    :ok
  end

  @impl true
  def handle_event({:postgres_changes, _op, payload}) do
    IO.inspect(payload, label: "DB change")
    :ok
  end

  @impl true
  def handle_event({:broadcast, event, payload}) do
    IO.inspect({event, payload}, label: "Broadcast")
    :ok
  end

  @impl true
  def handle_event({:presence, event, payload}) do
    IO.inspect({event, payload}, label: "Presence")
    :ok
  end
end
```

### Add to Your Supervision Tree

```elixir
def start(_type, _args) do
  {:ok, client} = Supabase.init_client(
    System.fetch_env!("SUPABASE_URL"),
    System.fetch_env!("SUPABASE_KEY")
  )

  children = [
    {MyApp.Realtime, client: client}
  ]

  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Subscribe to Database Changes

```elixir
{:ok, channel} = MyApp.Realtime.channel("public:users")

# All changes on the users table
MyApp.Realtime.on(channel, "postgres_changes",
  event: :all, schema: "public", table: "users"
)

# Only inserts
MyApp.Realtime.on(channel, "postgres_changes",
  event: :insert, schema: "public", table: "users"
)

# With a filter
MyApp.Realtime.on(channel, "postgres_changes",
  event: :update, schema: "public", table: "users",
  filter: "id=eq.1"
)
```

### Broadcast Messages

```elixir
# Subscribe
MyApp.Realtime.on(channel, "broadcast", event: "new_message")

# Send
MyApp.Realtime.broadcast(channel, "new_message", %{body: "Hello!"})
```

### Broadcast with Acknowledgment

```elixir
{:ok, channel} = MyApp.Realtime.channel("room", broadcast: [ack: true])
:ok = MyApp.Realtime.on(channel, "broadcast", event: "msg")

{:ok, ack_ref} = MyApp.Realtime.broadcast_with_ack(channel, "msg", %{body: "hi"})

case MyApp.Realtime.wait_for_ack(ack_ref, timeout: 5000) do
  {:ok, :acknowledged} -> :delivered
  {:error, :timeout} -> :lost
end
```

### Presence

```elixir
# Track
MyApp.Realtime.track(channel, %{user_id: 123, online_at: DateTime.utc_now()})

# Get current state
MyApp.Realtime.presence_state()

# Untrack
MyApp.Realtime.untrack(channel)
```

### HTTP Fallback

When the WebSocket is down, broadcast messages can be sent over HTTP:

```elixir
{MyApp.Realtime, client: client, http_fallback: true}
```

### Token Refresh

Provide a function to refresh tokens before each connection attempt:

```elixir
{MyApp.Realtime,
  client: client,
  access_token_fn: fn -> MyApp.Auth.get_fresh_token() end}
```

Or update tokens at runtime:

```elixir
MyApp.Realtime.set_auth("new-jwt-token")
```

### Unsubscribe

```elixir
MyApp.Realtime.unsubscribe(channel)
MyApp.Realtime.remove_all_channels()
```

## Guides

- [Installation](guides/installation.md)
- [Usage](guides/usage.md)
- [Phoenix Integration](guides/phoenix-integration.md)
- [Troubleshooting](guides/troubleshooting.md)

## References

- [Supabase Realtime Documentation](https://supabase.com/docs/guides/realtime)
- [supabase-ex Repository](https://github.com/zoedsoupe/supabase-ex)
- [HexDocs](https://hexdocs.pm/supabase_realtime)

## License

This project is licensed under the MIT License - see the [LICENSE](./LICENSE) file for details.

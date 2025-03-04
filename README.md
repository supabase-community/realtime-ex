# Supabase Realtime

[![Hex.pm](https://img.shields.io/hexpm/v/supabase_realtime.svg)](https://hex.pm/packages/supabase_realtime)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/supabase_realtime)

> [!WARNING]  
>
> This project is still in pre-release development. Expect breaking changes and evolving API.

Elixir client for the Supabase Realtime service, providing robust, OTP-powered connectivity for real-time database changes, broadcast messages, and presence features.

## Key Features

- **OTP-Powered Architecture**: Leverages Elixir's supervision trees for resilient connections and automatic recovery
- **Channel-Based Subscription Model**: Familiar subscription patterns inspired by Phoenix Channels
- **Automatic Reconnection**: Built-in exponential backoff reconnection strategy
- **Message Filtering**: Granular control over event types (INSERT, UPDATE, DELETE)

## Installation

Add `supabase_realtime` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:supabase_potion, "~> 0.6"},
    {:supabase_realtime, "~> 0.1"}
  ]
end
```

## Quick Start

### Basic Setup

Create a Realtime client module in your application:

```elixir
defmodule MyApp.Realtime do
  use Supabase.Realtime
  
  def start_link(opts \\ []) do
    Supabase.Realtime.start_link(__MODULE__, opts)
  end
  
  @impl true
  def handle_event({:postgres_changes, :insert, payload}) do
    # Handle database INSERT events
    IO.inspect(payload, label: "New record created")
  end
  
  @impl true
  def handle_event({:postgres_changes, :update, payload}) do
    # Handle database UPDATE events
    IO.inspect(payload, label: "Record updated")
  end
end
```

Add the client to your application's supervision tree:

```elixir
# In lib/my_app/application.ex
def start(_type, _args) do
  children = [
    # Other children...
    {MyApp.Supabase, name: MyApp.Supabase},
    {MyApp.Realtime, supabase_client: MyApp.Supabase}
  ]
  
  opts = [strategy: :one_for_one, name: MyApp.Supervisor]
  Supervisor.start_link(children, opts)
end
```

### Subscribing to Database Changes

```elixir
# Create a channel
channel = MyApp.Realtime.channel("public:users")

# Subscribe to all changes on the users table
MyApp.Realtime.on(channel, "postgres_changes", 
  event: "*", 
  schema: "public",
  table: "users"
)

# Or subscribe only to specific events
MyApp.Realtime.on(channel, "postgres_changes", 
  event: :insert, 
  schema: "public",
  table: "users"
)
```

### Broadcast Messages

```elixir
# Subscribe to broadcast events
MyApp.Realtime.on(channel, "broadcast", event: "new_message")

# Send a broadcast message
MyApp.Realtime.send(channel, type: "broadcast", event: "new_message", payload: %{
  body: "Hello world!",
  user_id: 123
})
```

### Managing Subscriptions

```elixir
# Unsubscribe from a channel
MyApp.Realtime.unsubscribe(channel)

# Remove all channels
MyApp.Realtime.remove_all_channels()
```

## Configuration

Configure your Realtime client in your application's configuration:

```elixir
# In config/config.exs or config/runtime.exs
config :my_app, MyApp.Realtime, heartbeat_interval: :timer.seconds(30),
```

## Integration with supabase-ex

`realtime-ex` is designed to work seamlessly with the existing Supabase Elixir ecosystem. It leverages the authentication and client management capabilities of `supabase-ex`, for example, considering a [self-managed](https://github.com/supabase-community/supabase-ex?tab=readme-ov-file#self-managed-clients) client:

```elixir
defmodule MyApp.Supabase do
  use Supabase.Client, otp_app: :my_app
end

defmodule MyApp.Realtime do
  use Supabase.Realtime
  
  def start_link(opts \\ []) do
    client = Keyword.get(opts, :supabase_client)
    Supabase.Realtime.start_link(__MODULE__, [client: client])
  end
  
  # Event handlers...
end
```

## References

- [Supabase Realtime Documentation](https://supabase.com/docs/guides/realtime)
- [Phoenix Channels Documentation](https://hexdocs.pm/phoenix/Phoenix.Channel.html)
- [supabase-ex Repository](https://github.com/zoedsoupe/supabase-ex)

## License

This project is licensed under the MIT License - see the [LICENSE](./LICENSE) file for details.

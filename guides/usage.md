# Usage

## How It Works

The Realtime client has three internal components:

1. **Connection** manages the WebSocket lifecycle: connecting, heartbeats,
   reconnection, and message transmission. When disconnected, messages go into
   a send buffer (up to 100 entries) and are flushed when the socket reopens.

2. **Channel Registry** receives messages from the Connection, matches them
   against your subscriptions, and calls your `handle_event/1` callback.

3. **Channel Store** keeps channel data in an ETS table so it survives across
   the application.

Events flow like this: WebSocket -> Connection -> Registry -> your callback.

## Channels

Channels scope your subscriptions to a topic. Create one with:

```elixir
{:ok, channel} = MyApp.Realtime.channel("room:lobby")
```

Topics are automatically prefixed with `realtime:` if not already present.

## Broadcast

### Sending

```elixir
MyApp.Realtime.broadcast(channel, "new_message", %{body: "hello"})
```

Or using the lower-level `send/2`:

```elixir
MyApp.Realtime.send(channel, %{
  type: "broadcast",
  event: "new_message",
  payload: %{body: "hello"}
})
```

### Receiving

Subscribe to broadcast events on a channel:

```elixir
:ok = MyApp.Realtime.on(channel, "broadcast", event: "new_message")
```

Then handle them in your callback:

```elixir
@impl true
def handle_event({:broadcast, "new_message", payload}) do
  IO.inspect(payload)
  :ok
end
```

### Broadcast Self

By default, you do not receive your own broadcast messages. Enable it with:

```elixir
{:ok, channel} = MyApp.Realtime.channel("room:lobby", broadcast: [self: true])
```

### Broadcast Acknowledgment

Enable delivery confirmation with:

```elixir
{:ok, channel} = MyApp.Realtime.channel("room:lobby", broadcast: [ack: true])
```

Then use `broadcast_with_ack/3` and `wait_for_ack/2`:

```elixir
{:ok, ack_ref} = MyApp.Realtime.broadcast_with_ack(channel, "event", %{data: 1})

case MyApp.Realtime.wait_for_ack(ack_ref, timeout: 5000) do
  {:ok, :acknowledged} -> :ok
  {:error, :timeout} -> :retry
end
```

### Wildcard Events

Listen to all broadcast events on a channel:

```elixir
:ok = MyApp.Realtime.on(channel, "broadcast", event: "*")
# or equivalently
:ok = MyApp.Realtime.on(channel, "broadcast", event: :all)
```

## Presence

Track your own state so other clients can see it:

```elixir
MyApp.Realtime.track(channel, %{user_id: 123, online_at: DateTime.utc_now()})
```

Stop tracking:

```elixir
MyApp.Realtime.untrack(channel)
```

Handle presence events:

```elixir
@impl true
def handle_event({:presence, :join, joins}) do
  IO.inspect(joins, label: "Users joined")
  :ok
end

@impl true
def handle_event({:presence, :leave, leaves}) do
  IO.inspect(leaves, label: "Users left")
  :ok
end

@impl true
def handle_event({:presence, :sync, state}) do
  IO.inspect(state, label: "Full presence state")
  :ok
end
```

Set a custom presence key:

```elixir
{:ok, channel} = MyApp.Realtime.channel("room:lobby", presence: [key: "user_123"])
```

## Postgres Changes

Subscribe to database changes:

```elixir
{:ok, channel} = MyApp.Realtime.channel("db-changes")

# All changes on a table
:ok = MyApp.Realtime.on(channel, "postgres_changes",
  event: :all, schema: "public", table: "messages"
)

# Only inserts
:ok = MyApp.Realtime.on(channel, "postgres_changes",
  event: :insert, schema: "public", table: "messages"
)

# With a filter
:ok = MyApp.Realtime.on(channel, "postgres_changes",
  event: :update, schema: "public", table: "messages",
  filter: "room_id=eq.42"
)
```

Handle the events:

```elixir
@impl true
def handle_event({:postgres_changes, :insert, payload}) do
  # payload includes "record", "old_record", "columns", etc.
  # Column values are automatically transformed to Elixir types
  # (integers, booleans, dates, JSON, etc.)
  :ok
end
```

See `Supabase.Realtime.PostgresTypes` for the full list of supported type
transforms.

## Connection State

Check the current connection state:

```elixir
MyApp.Realtime.connection_state()
# Returns :connecting | :open | :closing | :closed
```

You also receive connection state changes in your callback:

```elixir
@impl true
def handle_event({:connection, :state_change, %{old: old, new: new}}) do
  IO.puts("Connection changed from #{old} to #{new}")
  :ok
end
```

## Token Refresh

If your access token expires, provide an `:access_token_fn` when starting:

```elixir
{MyApp.Realtime,
  client: client,
  access_token_fn: fn -> MyApp.Auth.get_fresh_token() end}
```

This function is called before each WebSocket upgrade. If it returns
`{:error, _}`, the client falls back to `client.access_token` or
`client.apikey`.

You can also update the token at runtime for all channels:

```elixir
MyApp.Realtime.set_auth("new-jwt-token")
```

Or for a specific channel:

```elixir
MyApp.Realtime.set_auth(channel, "new-jwt-token")
```

## Error Handling

Realtime errors use `Supabase.Realtime.Error`:

```elixir
error = Supabase.Realtime.Error.new(:timeout, "Channel join timed out", %{topic: "realtime:room"})
```

Convert to the shared supabase-ex error format:

```elixir
supabase_error = Supabase.Realtime.Error.to_supabase_error(error)
# => %Supabase.Error{code: :timeout, service: :realtime, ...}
```

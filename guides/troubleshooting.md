# Troubleshooting

## Connection Issues

### WebSocket fails to connect

**Symptoms**: Logs show repeated "Failed to connect" messages.

**Causes**:

- Wrong project URL or API key in your `%Supabase.Client{}`.
- Network issues between your server and Supabase.
- Firewall blocking WebSocket (port 443) connections.

**Fix**: Verify your client config:

```elixir
{:ok, client} = Supabase.init_client("https://your-project.supabase.co", "your-api-key")
IO.inspect(client.realtime_url)
```

The `realtime_url` should point to your project's realtime endpoint.

### Connection keeps dropping

**Symptoms**: Frequent `:gun_down` messages in logs followed by reconnection.

**Causes**:

- Heartbeat interval too long, causing the server to close idle connections.
- Network instability.

**Fix**: Lower the heartbeat interval:

```elixir
{MyApp.Realtime, client: client, heartbeat_interval: :timer.seconds(15)}
```

The heartbeat tells the server the client is still alive. If the server does
not receive a heartbeat within its timeout, it closes the connection.

## Authentication Failures

### "unauthorized" or 401 errors

**Causes**:

- Expired or invalid API key.
- Expired access token.
- No token refresh function configured.

**Fix**: Provide an `access_token_fn` to refresh tokens:

```elixir
{MyApp.Realtime,
  client: client,
  access_token_fn: fn -> MyApp.Auth.get_fresh_token() end}
```

The token resolution order is:

1. `access_token_fn` result (if configured and returns `{:ok, token}`).
2. `client.access_token` from the struct.
3. `client.apikey` as a last resort.

## Missing Events

### Subscribed but not receiving events

**Causes**:

- Channel not joined yet. Subscriptions only work after the channel reaches
  the `:joined` state.
- Wrong topic or filter. Filters are case-sensitive and must match exactly.
- The `handle_event/1` callback does not match the event shape.
- Replication not enabled on the table in your Supabase dashboard.

**Fix**: Check the channel state and your subscription:

```elixir
{:ok, channel} = MyApp.Realtime.channel("public:users")
:ok = MyApp.Realtime.on(channel, "postgres_changes",
  event: :insert, schema: "public", table: "users"
)
```

Make sure your callback matches the event tuple:

```elixir
# This matches INSERT events
def handle_event({:postgres_changes, :insert, payload}), do: :ok

# This matches all database events
def handle_event({:postgres_changes, _operation, _payload}), do: :ok
```

Also verify that Realtime replication is enabled for the table in your
Supabase project dashboard under Database > Replication.

### Broadcast events not received

**Causes**:

- Not subscribed to the broadcast event name.
- Using `broadcast: [self: false]` (the default) and sending to yourself.

**Fix**: Subscribe with the exact event name:

```elixir
:ok = MyApp.Realtime.on(channel, "broadcast", event: "my_event")
```

Or use a wildcard to catch all events:

```elixir
:ok = MyApp.Realtime.on(channel, "broadcast", event: "*")
```

To receive your own broadcasts, enable `self`:

```elixir
{:ok, channel} = MyApp.Realtime.channel("room", broadcast: [self: true])
```

## Buffer Overflow

### Messages dropped while disconnected

**Symptoms**: Some messages sent during a disconnection are lost.

**Why**: The send buffer has a maximum size of 100 entries. When full, the
oldest messages are dropped to make room for new ones.

**Fix**: For important messages, use the HTTP fallback:

```elixir
{MyApp.Realtime, client: client, http_fallback: true}
```

With HTTP fallback enabled, broadcast messages are sent through the REST API
when the WebSocket is down. Other message types (presence, postgres_changes)
are still buffered.

## HTTP Fallback

### HTTP fallback not working

**Causes**:

- `http_fallback: true` was not set.
- The message is not a broadcast. Only broadcast messages use the HTTP fallback.
- Network issues reaching the Supabase REST API.

**Fix**: Make sure you enable it:

```elixir
{MyApp.Realtime, client: client, http_fallback: true}
```

Check logs for "[Supabase.Realtime.HTTP]: HTTP broadcast failed" messages.

### HTTP fallback succeeds but events not received

**Why**: HTTP fallback delivers the broadcast to the server, but other clients
need an active WebSocket connection to receive it. The fallback only helps with
sending, not receiving.

# Installation

## Dependencies

Add `supabase_realtime` and `supabase_potion` to your `mix.exs`:

```elixir
def deps do
  [
    {:supabase_potion, "~> 0.7"},
    {:supabase_realtime, "~> 0.4.0"} # x-release-please-version
  ]
end
```

Then fetch dependencies:

```sh
mix deps.get
```

## Creating a Client

Create a `%Supabase.Client{}` struct using `Supabase.init_client/3`:

```elixir
{:ok, client} = Supabase.init_client(
  "https://your-project.supabase.co",
  "your-api-key"
)
```

You can also pass additional options as a third argument:

```elixir
{:ok, client} = Supabase.init_client(
  "https://your-project.supabase.co",
  "your-api-key",
  %{access_token: "user-jwt-token"}
)
```

The client struct holds your project URL, API key, and derived service URLs
(auth, storage, realtime, etc.). It is passed directly to the Realtime
supervisor as the `:client` option.

## Defining a Realtime Module

Create a module that uses `Supabase.Realtime` and implements the
`handle_event/1` callback:

```elixir
defmodule MyApp.Realtime do
  use Supabase.Realtime

  def start_link(opts \\ []) do
    Supabase.Realtime.start_link(__MODULE__, opts)
  end

  @impl true
  def handle_event({:postgres_changes, operation, payload}) do
    IO.inspect({operation, payload}, label: "DB change")
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

The `use Supabase.Realtime` macro sets up a Supervisor that starts three
child processes: the WebSocket Connection, the Channel Registry, and the
Channel Store.

## Supervision Tree Setup

Add your Realtime module to your application supervisor:

```elixir
defmodule MyApp.Application do
  use Application

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
end
```

## Configuration Options

All options are passed to `start_link/2`:

| Option                | Type                 | Default             | Description                                                                                                                             |
| --------------------- | -------------------- | ------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `:client`             | `%Supabase.Client{}` | required            | The Supabase client struct                                                                                                              |
| `:name`               | atom                 | module name         | Process registration name                                                                                                               |
| `:heartbeat_interval` | integer (ms)         | 30000               | How often to send heartbeat pings. Keeps the WebSocket alive and detects dead connections.                                              |
| `:reconnect_after_ms` | function             | exponential backoff | A function `(attempts -> ms)` that controls the delay between reconnection attempts. The default doubles on each try, up to 10 seconds. |
| `:http_fallback`      | boolean              | false               | When true, broadcast messages are sent over HTTP if the WebSocket is down. Other message types are buffered.                            |
| `:access_token_fn`    | function or MFA      | nil                 | A zero-arity function returning `{:ok, token}` or `{:error, reason}`. Called before each WebSocket upgrade to get a fresh token.        |
| `:params`             | map                  | `%{}`               | Extra query parameters appended to the WebSocket URL. Useful for server-side logging or routing.                                        |

### Example with all options

```elixir
{MyApp.Realtime,
  client: client,
  heartbeat_interval: :timer.seconds(15),
  reconnect_after_ms: fn tries -> min(:timer.seconds(10), :timer.seconds(tries)) end,
  http_fallback: true,
  access_token_fn: fn -> MyApp.Auth.get_fresh_token() end,
  params: %{log_level: "debug"}}
```

# Phoenix Integration

## Application Supervisor

Set up the Realtime client in your Phoenix application:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    {:ok, client} = Supabase.init_client(
      System.fetch_env!("SUPABASE_URL"),
      System.fetch_env!("SUPABASE_KEY")
    )

    children = [
      MyAppWeb.Telemetry,
      {Phoenix.PubSub, name: MyApp.PubSub},
      {MyApp.Realtime, client: client},
      MyAppWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: MyApp.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

## Bridging Realtime Events to Phoenix PubSub

A practical pattern is to forward Supabase Realtime events to Phoenix PubSub.
This lets your LiveViews subscribe using the familiar PubSub interface:

```elixir
defmodule MyApp.Realtime do
  use Supabase.Realtime

  def start_link(opts \\ []) do
    Supabase.Realtime.start_link(__MODULE__, opts)
  end

  @impl true
  def handle_event({:postgres_changes, operation, payload}) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "db:changes",
      {:db_change, operation, payload}
    )

    :ok
  end

  @impl true
  def handle_event({:broadcast, event, payload}) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "realtime:broadcast",
      {:broadcast, event, payload}
    )

    :ok
  end

  @impl true
  def handle_event({:presence, event, payload}) do
    Phoenix.PubSub.broadcast(
      MyApp.PubSub,
      "realtime:presence",
      {:presence, event, payload}
    )

    :ok
  end
end
```

## LiveView Usage

Subscribe to PubSub events in `mount/3` so the LiveView receives updates.
We subscribe in `mount` because that is where the LiveView process starts
and it needs to register interest before any events arrive.

```elixir
defmodule MyAppWeb.MessagesLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "db:changes")
    end

    {:ok, assign(socket, messages: list_messages())}
  end

  def handle_info({:db_change, :insert, payload}, socket) do
    new_message = payload["record"]
    {:noreply, update(socket, :messages, fn msgs -> msgs ++ [new_message] end)}
  end

  def handle_info({:db_change, :delete, payload}, socket) do
    deleted_id = payload["old_record"]["id"]
    {:noreply, update(socket, :messages, fn msgs ->
      Enum.reject(msgs, &(&1["id"] == deleted_id))
    end)}
  end

  def handle_info({:db_change, _op, _payload}, socket) do
    # Catch-all for other operations
    {:noreply, socket}
  end
end
```

## Presence with LiveView

Track user presence in a LiveView and display who is online:

```elixir
defmodule MyAppWeb.RoomLive do
  use MyAppWeb, :live_view

  def mount(%{"room_id" => room_id}, session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(MyApp.PubSub, "realtime:presence")

      {:ok, channel} = MyApp.Realtime.channel("room:#{room_id}")
      :ok = MyApp.Realtime.on(channel, "presence", event: "sync")

      user_id = session["user_id"]
      MyApp.Realtime.track(channel, %{user_id: user_id, joined_at: DateTime.utc_now()})
    end

    {:ok, assign(socket, online_users: %{}, room_id: room_id)}
  end

  def handle_info({:presence, :sync, state}, socket) do
    {:noreply, assign(socket, :online_users, state)}
  end

  def handle_info({:presence, :join, joins}, socket) do
    {:noreply, update(socket, :online_users, &Map.merge(&1, joins))}
  end

  def handle_info({:presence, :leave, leaves}, socket) do
    {:noreply, update(socket, :online_users, &Map.drop(&1, Map.keys(leaves)))}
  end
end
```

## Handling Reconnections in LiveView

The Supabase Realtime client handles WebSocket reconnections automatically.
When the connection drops and reconnects, your channels rejoin and events
resume flowing.

If you need to react to connection state changes (for example, to show a
"reconnecting" banner), listen for connection state events:

```elixir
@impl true
def handle_event({:connection, :state_change, %{old: _old, new: :closed}}) do
  Phoenix.PubSub.broadcast(MyApp.PubSub, "realtime:status", :disconnected)
  :ok
end

@impl true
def handle_event({:connection, :state_change, %{old: _old, new: :open}}) do
  Phoenix.PubSub.broadcast(MyApp.PubSub, "realtime:status", :connected)
  :ok
end
```

Then in your LiveView:

```elixir
def mount(_params, _session, socket) do
  if connected?(socket) do
    Phoenix.PubSub.subscribe(MyApp.PubSub, "realtime:status")
  end

  {:ok, assign(socket, connected: true)}
end

def handle_info(:disconnected, socket) do
  {:noreply, assign(socket, connected: false)}
end

def handle_info(:connected, socket) do
  {:noreply, assign(socket, connected: true)}
end
```

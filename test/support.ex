defmodule Support.Client do
  @moduledoc false

  use Supabase.Client, otp_app: :supabase_realtime
end

defmodule Support.Realtime do
  @moduledoc false

  use Supabase.Realtime

  require Logger

  def start_link(opts) do
    Supabase.Realtime.start_link(__MODULE__, opts)
  end

  @impl Supabase.Realtime
  def handle_event(event) do
    Logger.debug("received event: #{inspect(event)}")
  end
end

defmodule Support.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(_ \\ []) do
    Supervisor.start_link(__MODULE__, :ok, name: Supabase.Realtime.Supervisor)
  end

  @impl true
  def init(:ok) do
    children = [
      Support.Client,
      {Support.Realtime, supabase_client: Support.Client, heartbeat_interval: :timer.hours(3)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

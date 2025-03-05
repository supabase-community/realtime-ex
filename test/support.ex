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

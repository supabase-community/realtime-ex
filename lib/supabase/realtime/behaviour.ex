defmodule Supabase.Realtime.Behaviour do
  @moduledoc "Defines the interface for the main module Supabase.Realtime"

  alias Supabase.Client
  alias Supabase.Realtime.Channel

  @type client :: module() | atom()
  @type t :: pid() | atom()
  @type channel :: Channel.t()
  @type event_type :: :postgres_changes | :broadcast | :presence
  @type event_filter :: Enumerable.t()
  @type channel_opts :: keyword()
  @type start_option :: {:name, atom()} | {:timeout, pos_integer()}

  @callback start_link(Client.t(), [start_option()]) :: Supervisor.on_start()
  @callback channel(t(), String.t(), channel_opts()) :: {:ok, channel()} | {:error, term()}
  @callback on(channel(), String.t(), event_filter()) :: :ok | {:error, term()}
  @callback send(t(), channel(), map()) :: :ok | {:error, term()}
  @callback unsubscribe(channel()) :: :ok | {:error, term()}
  @callback remove_all_channels(t()) :: :ok | {:error, term()}
  @callback connection_state(t()) :: Supabase.Realtime.connection_state()
  @callback track(t(), channel(), map()) :: :ok | {:error, term()}
  @callback untrack(t(), channel()) :: :ok | {:error, term()}
  @callback set_auth(t(), String.t()) :: :ok | {:error, term()}
  @callback set_auth(t(), channel(), String.t()) :: :ok | {:error, term()}
  @callback broadcast(t(), channel(), String.t(), map()) :: :ok | {:error, term()}
end
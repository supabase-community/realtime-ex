defmodule Supabase.Realtime.Error do
  @moduledoc """
  Structured error for Supabase Realtime operations.

  Provides a standard error struct with a reason atom, a human-readable message,
  and an optional context map. Implements the `Exception` behaviour so it can
  be raised or matched in rescue blocks.

  ## Creating Errors

      error = Supabase.Realtime.Error.new(:not_connected, "WebSocket is not open")
      #=> %Supabase.Realtime.Error{reason: :not_connected, message: "WebSocket is not open", context: %{}}

      error = Supabase.Realtime.Error.new(:timeout, "Channel join timed out", %{topic: "realtime:room"})
      #=> %Supabase.Realtime.Error{reason: :timeout, message: "Channel join timed out", context: %{topic: "realtime:room"}}

  ## Converting to Supabase.Error

  Use `to_supabase_error/1` to convert a Realtime error into a `Supabase.Error`
  struct. This is useful for passing errors to code that expects the shared
  supabase-ex error format.

      error = Supabase.Realtime.Error.new(:not_connected, "WebSocket is not open")
      supabase_error = Supabase.Realtime.Error.to_supabase_error(error)
      supabase_error.code     #=> :not_connected
      supabase_error.service  #=> :realtime
  """

  @type t :: %__MODULE__{
          reason: atom(),
          message: String.t(),
          context: map()
        }

  defexception [:reason, :message, context: %{}]

  @impl true
  def message(%__MODULE__{reason: reason, message: msg, context: ctx}) do
    base = "#{reason}: #{msg}"
    if ctx == %{}, do: base, else: "#{base} (#{inspect(ctx)})"
  end

  @doc """
  Creates a new error struct.
  """
  @spec new(atom(), String.t(), map()) :: t()
  def new(reason, message, context \\ %{}) do
    %__MODULE__{reason: reason, message: message, context: context}
  end

  @doc """
  Converts a `Supabase.Realtime.Error` to a `Supabase.Error` struct.

  This allows interoperability with the broader supabase-ex error handling.

  ## Examples

      iex> error = Supabase.Realtime.Error.new(:not_connected, "WebSocket is not connected")
      iex> supabase_error = Supabase.Realtime.Error.to_supabase_error(error)
      iex> supabase_error.code
      :not_connected
      iex> supabase_error.service
      :realtime
  """
  @spec to_supabase_error(t()) :: Supabase.Error.t()
  def to_supabase_error(%__MODULE__{reason: reason, message: message, context: context}) do
    Supabase.Error.new(code: reason, message: message, service: :realtime, metadata: context)
  end
end

defmodule Supabase.Realtime.Error do
  @moduledoc """
  Structured error for Supabase Realtime operations.
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
end

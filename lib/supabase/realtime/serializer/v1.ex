defmodule Supabase.Realtime.Serializer.V1 do
  @moduledoc """
  vsn "1.0.0" serializer: JSON objects in text frames. The default.

  Matches `Phoenix.Socket.V1.JSONSerializer` on the server side: outbound
  frames are the JSON encoding of the message map (atom keys become JSON
  object keys, extra keys pass through untouched); inbound text frames decode
  to string-keyed maps.
  """

  @behaviour Supabase.Realtime.Serializer

  alias Supabase.Realtime.Serializer

  @impl true
  @spec encode(Serializer.message(), Serializer.opts()) ::
          {:ok, {:text, binary()}} | {:error, {:encode_failed, term()}}
  def encode(message, _opts) do
    with {:ok, json} <- encode_json(message), do: {:ok, {:text, json}}
  end

  @impl true
  @spec decode(Serializer.frame(), Serializer.opts()) ::
          {:ok, Serializer.decoded()} | {:error, term()}
  def decode({:text, data}, _opts) do
    case JSON.decode(data) do
      {:ok, %{} = message} ->
        {:ok, message}

      {:ok, other} ->
        {:error, {:unexpected_text_frame, other}}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  def decode({:binary, _data}, _opts), do: {:error, {:unexpected_frame, :binary}}

  # Native JSON has no tuple-returning encode/1, so the bang function is
  # wrapped once here at the wire boundary. Callers keep the
  # {:ok, _} | {:error, _} contract.
  defp encode_json(term) do
    {:ok, JSON.encode!(term)}
  rescue
    e -> {:error, {:encode_failed, e}}
  end
end

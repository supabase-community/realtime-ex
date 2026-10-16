defmodule Supabase.Realtime.Serializer.V2 do
  @moduledoc """
  vsn "2.0.0" serializer: JSON arrays in text frames, binary framing for user
  broadcasts. Byte-compatible with realtime-js `serializer.ts` and the
  server's `RealtimeWeb.Socket.V2Serializer`.

  Outbound:

  * `"broadcast"` events whose payload is a map with a binary `:event` key are
    encoded as binary kind-3 frames (`userBroadcastPush`).
  * Everything else is a JSON array `[join_ref, ref, topic, event, payload]`
    in a text frame.

  Inbound:

  * `{:binary, data}` frames with kind 4 (`userBroadcast`) are decoded into
    broadcast message maps. Other kinds are `{:error, {:unsupported_kind, kind}}`
    (the server never sends kinds 0/1/2 to SDK clients).
  * `{:text, data}` frames are JSON arrays `[join_ref, ref, topic, event, payload]`.

  ## Options

  * `:allowed_metadata_keys` - keys (atoms) picked from the outbound broadcast
    payload map into the metadata section, JSON-encoded. Default `[]`, which
    always produces an empty metadata section, byte-identical with the
    realtime-js default.
  """

  @behaviour Supabase.Realtime.Serializer

  alias Supabase.Realtime.Serializer

  @user_broadcast_push 3
  @user_broadcast 4
  @binary_encoding 0
  @json_encoding 1
  @broadcast_event "broadcast"

  @impl true
  @spec encode(Serializer.message(), Serializer.opts()) ::
          {:ok, {:binary, binary()} | {:text, binary()}} | {:error, term()}
  def encode(%{event: @broadcast_event, payload: %{event: user_event} = payload} = message, opts)
      when is_binary(user_event) do
    join_ref = message[:join_ref] || ""
    ref = message[:ref] || ""
    topic = message.topic
    metadata = encode_metadata(payload, Keyword.get(opts, :allowed_metadata_keys, []))

    with {:ok, encoding, user_payload} <- encoded_user_payload(payload[:payload]),
         :ok <- guard_size(:join_ref, join_ref),
         :ok <- guard_size(:ref, ref),
         :ok <- guard_size(:topic, topic),
         :ok <- guard_size(:user_event, user_event),
         :ok <- guard_size(:metadata, metadata) do
      join_ref_size = byte_size(join_ref)
      ref_size = byte_size(ref)
      topic_size = byte_size(topic)
      user_event_size = byte_size(user_event)
      metadata_size = byte_size(metadata)

      frame = <<
        @user_broadcast_push,
        join_ref_size::size(8),
        ref_size::size(8),
        topic_size::size(8),
        user_event_size::size(8),
        metadata_size::size(8),
        encoding::size(8),
        join_ref::binary-size(join_ref_size),
        ref::binary-size(ref_size),
        topic::binary-size(topic_size),
        user_event::binary-size(user_event_size),
        metadata::binary-size(metadata_size),
        user_payload::binary
      >>

      {:ok, {:binary, frame}}
    end
  end

  def encode(message, _opts) do
    with {:ok, json} <-
           encode_json([message[:join_ref], message[:ref], message.topic, message.event, message.payload], :encode_failed) do
      {:ok, {:text, json}}
    end
  end

  @impl true
  @spec decode(Serializer.frame(), Serializer.opts()) ::
          {:ok, Serializer.decoded()} | {:error, term()}
  def decode({:binary, data}, _opts) do
    case data do
      <<
        @user_broadcast,
        topic_size::size(8),
        user_event_size::size(8),
        metadata_size::size(8),
        payload_encoding::size(8),
        topic::binary-size(topic_size),
        user_event::binary-size(user_event_size),
        metadata::binary-size(metadata_size),
        user_payload::binary
      >> ->
        decode_user_broadcast(topic, user_event, metadata, metadata_size, payload_encoding, user_payload)

      <<kind, _::binary>> ->
        {:error, {:unsupported_kind, kind}}
    end
  end

  def decode({:text, data}, _opts) do
    case JSON.decode(data) do
      {:ok, [join_ref, ref, topic, event, payload | _]} ->
        {:ok, %{"join_ref" => join_ref, "ref" => ref, "topic" => topic, "event" => event, "payload" => payload}}

      {:ok, other} ->
        {:error, {:unexpected_text_frame, other}}

      {:error, reason} ->
        {:error, {:invalid_json, reason}}
    end
  end

  # nil user payload -> JSON {} (JS: message.payload?.payload ?? {})
  defp encoded_user_payload(nil), do: encoded_user_payload(%{})

  defp encoded_user_payload(payload) when is_binary(payload), do: {:ok, @binary_encoding, payload}

  defp encoded_user_payload(payload) do
    with {:ok, json} <- encode_json(payload, :invalid_payload), do: {:ok, @json_encoding, json}
  end

  # JS parity: pick allowed keys; empty pick -> empty metadata bytes, not "{}"
  defp encode_metadata(_payload, []), do: ""

  defp encode_metadata(payload, keys) do
    case Map.take(payload, keys) do
      picked when map_size(picked) == 0 -> ""
      picked -> JSON.encode!(picked)
    end
  end

  defp guard_size(field, value) do
    case byte_size(value) do
      size when size <= 255 -> :ok
      size -> {:error, {:field_too_long, field, size}}
    end
  end

  defp decode_user_broadcast(topic, user_event, _metadata, 0 = _metadata_size, payload_encoding, user_payload) do
    with {:ok, parsed} <- parse_payload(payload_encoding, user_payload) do
      {:ok,
       %{
         "join_ref" => nil,
         "ref" => nil,
         "topic" => topic,
         "event" => "broadcast",
         "payload" => %{"type" => "broadcast", "event" => user_event, "payload" => parsed}
       }}
    end
  end

  defp decode_user_broadcast(topic, user_event, metadata, _metadata_size, payload_encoding, user_payload) do
    with {:ok, meta} <- decode_metadata(metadata),
         {:ok, parsed} <- parse_payload(payload_encoding, user_payload) do
      {:ok,
       %{
         "join_ref" => nil,
         "ref" => nil,
         "topic" => topic,
         "event" => "broadcast",
         "payload" => %{"type" => "broadcast", "event" => user_event, "payload" => parsed, "meta" => meta}
       }}
    end
  end

  defp decode_metadata(metadata) do
    case JSON.decode(metadata) do
      {:ok, meta} -> {:ok, meta}
      {:error, reason} -> {:error, {:invalid_json, reason}}
    end
  end

  defp parse_payload(@json_encoding, payload) do
    case JSON.decode(payload) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, {:invalid_payload, reason}}
    end
  end

  defp parse_payload(@binary_encoding, payload), do: {:ok, payload}

  # Native JSON has no tuple-returning encode/1, so the bang function is
  # wrapped once here at the wire boundary. Callers keep the
  # {:ok, _} | {:error, _} contract.
  defp encode_json(term, error_tag) do
    {:ok, JSON.encode!(term)}
  rescue
    e -> {:error, {error_tag, e}}
  end
end

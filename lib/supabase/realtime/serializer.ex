defmodule Supabase.Realtime.Serializer do
  @moduledoc """
  Behaviour for Realtime websocket message serialization.

  Implementations turn outbound message maps into gun-ready frames and inbound
  gun frames into the string-keyed message maps the Channel Registry consumes.

  Built-in serializers:

  * `Supabase.Realtime.Serializer.V1` - vsn "1.0.0" (default). JSON objects in
    text frames, the historical wire format.
  * `Supabase.Realtime.Serializer.V2` - vsn "2.0.0". JSON arrays in text
    frames, plus binary framing for user broadcast pushes (client to server)
    and user broadcasts (server to client).

  Pass a custom module with the `:serializer` option to
  `Supabase.Realtime.start_link/2`. The module must implement `encode/2` and
  `decode/2`. The `:vsn` option is forwarded verbatim in the websocket query
  string and must match the wire format the server negotiates for your
  serializer.
  """

  @typedoc ~s(Realtime protocol version, e.g. "1.0.0" or "2.0.0".)
  @type vsn :: String.t()

  @typedoc """
  Outbound message, as built by `Supabase.Realtime.Message` builders and the
  Connection. Atom-keyed. `:join_ref` and `:ref` may be absent (the serializer
  encodes them as empty/JSON null; it must never invent or mutate refs).
  """
  @type message :: %{
          required(:topic) => String.t(),
          required(:event) => String.t(),
          required(:payload) => term(),
          optional(:ref) => String.t() | nil,
          optional(:join_ref) => String.t() | nil,
          optional(atom()) => term()
        }

  @typedoc """
  Inbound message after decode, in the shape the Channel Registry consumes:
  a string-keyed map with `"topic"`, `"event"`, `"payload"`, `"ref"`, and
  (vsn 2.0.0) `"join_ref"` keys.
  """
  @type decoded :: %{optional(String.t()) => term()}

  @typedoc "A gun websocket frame, ready for `:gun.ws_send/3`."
  @type frame :: {:text, binary()} | {:binary, binary()}

  @typedoc "Serializer options; see the implementation modules for supported keys."
  @type opts :: keyword()

  @typedoc "Resolution failures for `resolve/1`."
  @type resolve_error ::
          {:unsupported_vsn, String.t()} | {:invalid_serializer, module()}

  @doc """
  Encodes an outbound message into a websocket frame.

  ## Options

  None for `V1`. `V2` accepts `:allowed_metadata_keys` (see `V2` docs).
  """
  @callback encode(message(), opts()) :: {:ok, frame()} | {:error, term()}

  @doc """
  Decodes an inbound websocket frame into a message map. The opcode is part of
  the wire contract: `V2` decodes `{:binary, data}` with kind-4 framing and
  `{:text, data}` as JSON arrays; `V1` decodes `{:text, data}` as JSON objects
  and rejects binary frames.
  """
  @callback decode(frame(), opts()) :: {:ok, decoded()} | {:error, term()}

  @doc """
  Resolves the serializer module and the effective vsn from client options.

  Reads `:serializer` and `:vsn`:

  * `:serializer` given - used verbatim after a structural check. The vsn is
    the `:vsn` value if given, otherwise "1.0.0". Callers are responsible for
    the serializer matching the wire format the server negotiates for that vsn.
  * no `:serializer` - derived from `:vsn` (default "1.0.0"):
    "1.0.0" -> `Serializer.V1`, "2.0.0" -> `Serializer.V2`.

  ## Examples

      iex> Supabase.Realtime.Serializer.resolve([])
      {:ok, Supabase.Realtime.Serializer.V1, "1.0.0"}

      iex> Supabase.Realtime.Serializer.resolve(vsn: "2.0.0")
      {:ok, Supabase.Realtime.Serializer.V2, "2.0.0"}

      iex> Supabase.Realtime.Serializer.resolve(vsn: "9.9.9")
      {:error, {:unsupported_vsn, "9.9.9"}}
  """
  @spec resolve(keyword()) :: {:ok, module(), vsn()} | {:error, resolve_error()}
  def resolve(opts) do
    vsn = Keyword.get(opts, :vsn, "1.0.0")

    case Keyword.get(opts, :serializer) do
      nil -> default(vsn)
      module when is_atom(module) -> validate(module, vsn)
    end
  end

  defp default("1.0.0"), do: {:ok, Supabase.Realtime.Serializer.V1, "1.0.0"}
  defp default("2.0.0"), do: {:ok, Supabase.Realtime.Serializer.V2, "2.0.0"}
  defp default(vsn), do: {:error, {:unsupported_vsn, vsn}}

  defp validate(module, vsn) do
    with {:module, _} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :encode, 2),
         true <- function_exported?(module, :decode, 2) do
      {:ok, module, vsn}
    else
      _ -> {:error, {:invalid_serializer, module}}
    end
  end
end

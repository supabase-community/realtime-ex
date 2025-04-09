defmodule Supabase.Realtime.Channel do
  @moduledoc """
  Represents a subscription channel for Supabase Realtime events.

  A channel narrows the scope of data flow to subscribed clients. Channels are
  created with a topic and can have multiple event subscriptions.
  """

  alias Supabase.Realtime

  @typedoc """
  Channel structure for Supabase Realtime subscriptions.

  Fields:
  * `topic` - The channel topic string
  * `registry` - The channel registry process or module
  * `bindings` - Event bindings for this channel
  * `state` - Current state of the channel
  * `join_ref` - Reference for the join message
  * `timeout` - Timeout for operations in milliseconds
  * `params` - Additional parameters for the channel
  * `ref` - Unique reference for this channel
  """
  @type t :: %__MODULE__{
          topic: String.t(),
          registry: pid() | atom(),
          bindings: map(),
          state: Realtime.channel_state(),
          join_ref: Realtime.ref() | nil,
          timeout: pos_integer(),
          params: map(),
          ref: String.t()
        }

  @enforce_keys [:topic, :registry]
  defstruct [
    :topic,
    :registry,
    :join_ref,
    :ref,
    bindings: %{},
    state: :closed,
    timeout: 10_000,
    params: %{
      config: %{
        broadcast: %{ack: false, self: false},
        presence: %{key: ""},
        private: false
      }
    }
  ]

  @doc """
  Creates a new channel struct.

  ## Parameters

  * `topic` - The topic to subscribe to
  * `registry` - The channel registry module or PID
  * `opts` - Additional options for the channel

  ## Options

  * `:timeout` - Timeout for operations in milliseconds (default: 10000)
  * `:params` - Additional parameters for the channel
  * `:ref` - Optional reference for the channel

  ## Returns

  * `%Channel{}` - A channel struct
  """
  @spec new(String.t(), pid() | atom(), keyword()) :: t()
  def new(topic, registry, opts \\ []) do
    topic = if String.starts_with?(topic, "realtime:"), do: topic, else: "realtime:#{topic}"

    params = opts[:params] || %{}
    config = Map.get(params, :config, %{})

    default_config = %{
      broadcast: %{ack: false, self: false},
      presence: %{key: ""},
      private: false
    }

    merged_config = Map.merge(default_config, config)
    merged_params = Map.put(params, :config, merged_config)

    %__MODULE__{
      topic: topic,
      registry: registry,
      timeout: opts[:timeout] || 10_000,
      params: merged_params,
      ref: opts[:ref] || generate_ref()
    }
  end

  @doc """
  Updates the channel state.

  ## Parameters

  * `channel` - The channel struct
  * `state` - The new state

  ## Returns

  * `%Channel{}` - Updated channel struct
  """
  @spec update_state(t(), Realtime.channel_state()) :: t()
  def update_state(%__MODULE__{} = channel, state)
      when state in [:closed, :errored, :joined, :joining, :leaving] do
    %{channel | state: state}
  end

  @doc """
  Sets the join reference for the channel.

  ## Parameters

  * `channel` - The channel struct
  * `join_ref` - The join reference

  ## Returns

  * `%Channel{}` - Updated channel struct
  """
  @spec set_join_ref(t(), Realtime.ref()) :: t()
  def set_join_ref(%__MODULE__{} = channel, join_ref) when is_binary(join_ref) do
    %{channel | join_ref: join_ref}
  end

  @doc """
  Adds a binding for an event type.

  ## Parameters

  * `channel` - The channel struct
  * `type` - The event type
  * `filter` - The event filter
  * `callback` - Optional callback function

  ## Returns

  * `%Channel{}` - Updated channel struct
  """
  @spec add_binding(t(), String.t(), Enumerable.t(), (map() -> any()) | nil) :: t()
  def add_binding(%__MODULE__{} = channel, type, filter, callback \\ nil) do
    filter = if is_list(filter), do: Map.new(filter), else: filter

    binding = %{
      type: type,
      filter: filter,
      callback: callback,
      id: Map.get(filter, :id)
    }

    updated_bindings =
      Map.update(
        channel.bindings,
        type,
        [binding],
        &[binding | &1]
      )

    %{channel | bindings: updated_bindings}
  end

  @doc """
  Removes bindings for an event type.

  ## Parameters

  * `channel` - The channel struct
  * `type` - The event type
  * `filter` - The event filter

  ## Returns

  * `%Channel{}` - Updated channel struct
  """
  @spec remove_binding(t(), String.t(), map() | keyword()) :: t()
  def remove_binding(%__MODULE__{} = channel, type, filter) do
    filter = if is_list(filter), do: Map.new(filter), else: filter

    updated_bindings =
      Map.update(
        channel.bindings,
        type,
        [],
        &Enum.reject(&1, fn bind -> binding_match?(bind, filter) end)
      )

    %{channel | bindings: updated_bindings}
  end

  @doc """
  Checks if the channel is joined (subscribed).

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `boolean` - True if joined, false otherwise
  """
  @spec joined?(t()) :: boolean()
  def joined?(%__MODULE__{state: :joined}), do: true
  def joined?(_), do: false

  @doc """
  Checks if the channel is in the process of joining.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `boolean` - True if joining, false otherwise
  """
  @spec joining?(t()) :: boolean()
  def joining?(%__MODULE__{state: :joining}), do: true
  def joining?(_), do: false

  @doc """
  Checks if the channel is in the process of leaving.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `boolean` - True if leaving, false otherwise
  """
  @spec leaving?(t()) :: boolean()
  def leaving?(%__MODULE__{state: :leaving}), do: true
  def leaving?(_), do: false

  @doc """
  Checks if the channel is closed.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `boolean` - True if closed, false otherwise
  """
  @spec closed?(t()) :: boolean()
  def closed?(%__MODULE__{state: :closed}), do: true
  def closed?(_), do: false

  @doc """
  Checks if the channel is in an error state.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `boolean` - True if errored, false otherwise
  """
  @spec errored?(t()) :: boolean()
  def errored?(%__MODULE__{state: :errored}), do: true
  def errored?(_), do: false

  @doc """
  Checks if a push can be sent on this channel.

  A push can be sent when the channel is joined and the client is connected.

  ## Parameters

  * `channel` - The channel struct

  ## Returns

  * `boolean` - True if a push can be sent, false otherwise
  """
  @spec can_push?(t()) :: boolean()
  def can_push?(%__MODULE__{state: :joined}), do: true
  def can_push?(_), do: false

  # Private helper functions

  defp binding_match?(binding, filter) do
    filter_keys = Map.keys(filter)

    Enum.all?(filter_keys, fn key ->
      Map.get(binding.filter, key) == Map.get(filter, key)
    end)
  end

  defp generate_ref do
    "channel:" <> (:crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower))
  end
end

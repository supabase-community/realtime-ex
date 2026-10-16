defmodule Supabase.Realtime.Rejoin do
  @moduledoc """
  Per-channel rejoin backoff (phoenix `Timer` + `rejoinAfterMs` semantics).

  The delay for an arm is `after_ms.(tries + 1)` where `tries` counts FIRED
  timers, not arms: an arm that replaces a never-fired timer re-reads the
  same `tries`. The default sequence is 1s, 2s, 5s, then 10s forever.
  """

  @intervals [1_000, 2_000, 5_000]
  @fallback 10_000

  @type entry :: %{tries: non_neg_integer(), token: reference(), timer: reference() | nil}
  @type timers :: %{optional(String.t()) => entry()}
  @type after_ms :: (pos_integer() -> pos_integer())

  @spec default_after_ms(pos_integer()) :: pos_integer()
  def default_after_ms(tries), do: Enum.at(@intervals, tries - 1, @fallback)

  @doc "Delay for the upcoming arm. `nil` entry means a first arm (tries 0)."
  @spec arm_delay(entry() | nil, after_ms()) :: pos_integer()
  def arm_delay(nil, after_ms), do: after_ms.(1)
  def arm_delay(%{tries: tries}, after_ms), do: after_ms.(tries + 1)

  @doc "Entry after a valid fire: tries increments at fire (phoenix Timer)."
  @spec fired(entry()) :: entry()
  def fired(%{} = entry), do: %{entry | tries: entry.tries + 1, timer: nil}

  @doc "Whether this fire is the current arm (BEAM cannot unsend a timer msg)."
  @spec valid_fire?(timers(), String.t(), reference()) :: boolean()
  def valid_fire?(timers, ref, token) do
    case Map.get(timers, ref) do
      %{token: ^token} -> true
      _ -> false
    end
  end
end

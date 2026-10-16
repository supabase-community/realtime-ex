defmodule Supabase.Realtime.Presence do
  @moduledoc """
  Pure presence state algebra, mirroring phoenix's `Presence.syncDiff`.

  Operates on wire-shaped maps (string keys) exactly as the server sends
  them. `phx_ref` is the merge key: a diff join for a key that already
  exists merges metas per ref instead of replacing the whole key, and a
  diff leave removes only the listed refs, deleting the key only when no
  metas remain.
  """

  @type meta :: %{optional(String.t()) => term()}
  @type entry :: %{optional(String.t()) => term()}
  @type state :: %{optional(String.t()) => entry()}

  # Wire shape: %{"joins" => state(), "leaves" => state()} with either key
  # optional. Typespecs cannot express string-literal map keys, so the exact
  # keys are documented here and read defensively with Map.get/3.
  @type diff :: %{optional(String.t()) => state()}

  @doc """
  Applies a `presence_diff` payload to the presence state.

  Joins are applied before leaves (phoenix's order). Returns the updated
  state.
  """
  @spec sync_diff(state(), diff()) :: state()
  def sync_diff(state, diff) do
    state
    |> apply_joins(Map.get(diff, "joins", %{}))
    |> apply_leaves(Map.get(diff, "leaves", %{}))
  end

  defp apply_joins(state, joins) do
    Enum.reduce(joins, state, fn {key, new_entry}, acc ->
      case Map.get(acc, key) do
        nil ->
          Map.put(acc, key, new_entry)

        %{"metas" => current_metas} = _current_entry ->
          joined_refs = Enum.map(new_entry["metas"], & &1["phx_ref"])

          # keep current metas whose ref was NOT re-joined, prepend them
          # before the new metas (phoenix: state[key] = new; unshift(cur))
          surviving = Enum.reject(current_metas, &(&1["phx_ref"] in joined_refs))
          Map.put(acc, key, Map.put(new_entry, "metas", surviving ++ new_entry["metas"]))
      end
    end)
  end

  defp apply_leaves(state, leaves) do
    Enum.reduce(leaves, state, fn {key, left_entry}, acc ->
      case Map.get(acc, key) do
        nil ->
          acc

        %{"metas" => current_metas} = current_entry ->
          left_refs = Enum.map(left_entry["metas"], & &1["phx_ref"])
          remaining = Enum.reject(current_metas, &(&1["phx_ref"] in left_refs))

          if remaining == [] do
            Map.delete(acc, key)
          else
            Map.put(acc, key, Map.put(current_entry, "metas", remaining))
          end
      end
    end)
  end
end

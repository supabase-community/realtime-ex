defmodule Supabase.Realtime.PresenceTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Presence

  defp entry(refs), do: %{"metas" => Enum.map(refs, &%{"phx_ref" => &1})}
  defp refs(state, key), do: Enum.map(state[key]["metas"], & &1["phx_ref"])

  test "P1: a join for a new key adds the entry verbatim" do
    state = Presence.sync_diff(%{}, %{"joins" => %{"u1" => entry(["r1"])}, "leaves" => %{}})
    assert state == %{"u1" => %{"metas" => [%{"phx_ref" => "r1"}]}}
  end

  test "P2: joins merge per phx_ref on an existing key (multi-device regression)" do
    state = %{"u1" => entry(["r1"])}

    state = Presence.sync_diff(state, %{"joins" => %{"u1" => entry(["r2"])}, "leaves" => %{}})

    assert refs(state, "u1") == ["r1", "r2"]
  end

  test "P3: re-joining an already present phx_ref does not duplicate it" do
    state = %{"u1" => entry(["r1"])}

    state = Presence.sync_diff(state, %{"joins" => %{"u1" => entry(["r1"])}, "leaves" => %{}})

    assert refs(state, "u1") == ["r1"]
  end

  test "P4: a leave removes only the listed refs (partial leave regression)" do
    state = %{"u1" => entry(["r1", "r2"])}

    state = Presence.sync_diff(state, %{"joins" => %{}, "leaves" => %{"u1" => entry(["r2"])}})

    assert Map.has_key?(state, "u1")
    assert refs(state, "u1") == ["r1"]
  end

  test "P5: leaving the last meta deletes the key" do
    state = %{"u1" => entry(["r1"])}

    state = Presence.sync_diff(state, %{"joins" => %{}, "leaves" => %{"u1" => entry(["r1"])}})

    assert state == %{}
  end

  test "P6: a leave for an unknown key is a no-op" do
    state = Presence.sync_diff(%{}, %{"joins" => %{}, "leaves" => %{"ghost" => entry(["r1"])}})
    assert state == %{}
  end

  test "P7: joins apply before leaves for the same key (phoenix order)" do
    state = %{"u1" => entry(["r1"])}

    state =
      Presence.sync_diff(state, %{
        "joins" => %{"u1" => entry(["r2"])},
        "leaves" => %{"u1" => entry(["r1"])}
      })

    assert refs(state, "u1") == ["r2"]
  end

  test "P8: missing joins/leaves keys default to empty maps" do
    assert Presence.sync_diff(%{"u1" => entry(["r1"])}, %{}) == %{"u1" => entry(["r1"])}
  end
end

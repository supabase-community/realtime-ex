defmodule Supabase.Realtime.SerializerTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Serializer

  # A minimal custom serializer for resolve/1 structural checks.
  defmodule CustomSerializer do
    @moduledoc false
    @behaviour Serializer

    @impl true
    def encode(message, _opts), do: {:ok, {:text, JSON.encode!(message)}}

    @impl true
    def decode({:text, data}, _opts), do: JSON.decode(data)
    def decode({:binary, _data}, _opts), do: {:error, {:unexpected_frame, :binary}}
  end

  describe "resolve/1" do
    test "defaults to V1 with vsn 1.0.0" do
      assert {:ok, Supabase.Realtime.Serializer.V1, "1.0.0"} = Serializer.resolve([])
    end

    test "derives V2 from vsn 2.0.0" do
      assert {:ok, Supabase.Realtime.Serializer.V2, "2.0.0"} = Serializer.resolve(vsn: "2.0.0")
    end

    test "rejects an unsupported vsn" do
      assert {:error, {:unsupported_vsn, "9.9.9"}} = Serializer.resolve(vsn: "9.9.9")
    end

    test "uses a custom module with the default vsn" do
      assert {:ok, CustomSerializer, "1.0.0"} = Serializer.resolve(serializer: CustomSerializer)
    end

    test "forwards an explicit vsn verbatim for a custom module" do
      assert {:ok, CustomSerializer, "1.2.3"} = Serializer.resolve(serializer: CustomSerializer, vsn: "1.2.3")
    end

    test "rejects a module without the callbacks" do
      assert {:error, {:invalid_serializer, String}} = Serializer.resolve(serializer: String)
    end
  end
end

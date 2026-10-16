defmodule Supabase.Realtime.BindingDedupTest do
  use ExUnit.Case, async: false

  alias Supabase.Realtime.Channel.Registry
  alias Supabase.Realtime.Channel.Store
  alias Supabase.Realtime.Filter

  @moduletag capture_log: true

  setup do
    unique_id = System.unique_integer([:positive])
    store_name = :"Store#{unique_id}"
    registry_name = :"Registry#{unique_id}"

    start_supervised!({Store, name: store_name})

    # armed rejoin timers must stay inert during the test
    start_supervised!(
      {Registry, module: RealtimeTest, name: registry_name, store: store_name, rejoin_after_ms: fn _ -> 60_000 end}
    )

    {:ok, channel} = Registry.create_channel(registry_name, "dedup-topic")

    %{registry: registry_name, store: store_name, channel: channel}
  end

  # Moves the channel out of :joining without a Connection: set a join_ref
  # manually and feed an error join reply through Registry.handle_message,
  # so the channel lands :errored and further postgres subscribes are allowed.
  defp force_errored(ctx) do
    # Store updates replace the whole struct: re-read so bindings already
    # subscribed are not wiped by this helper's own updates
    {:ok, current} = Store.find_by_ref(ctx.store, ctx.channel.ref)

    join_ref = "jr-#{System.unique_integer([:positive])}"
    {:ok, channel} = Store.update_join_ref(ctx.store, current, join_ref)
    {:ok, _} = Store.update_state(ctx.store, channel, :joining)

    Registry.handle_message(ctx.registry, %{
      "topic" => channel.topic,
      "event" => "phx_reply",
      "ref" => join_ref,
      "payload" => %{"status" => "error", "response" => %{"reason" => "unauthorized"}}
    })

    Process.sleep(50)
    {:ok, channel} = Store.find_by_ref(ctx.store, channel.ref)
    assert channel.state == :errored
    channel
  end

  defp stored_bindings(ctx) do
    {:ok, stored} = Store.find_by_ref(ctx.store, ctx.channel.ref)
    Map.get(stored.bindings, "postgres_changes", [])
  end

  describe "duplicate binding dedup" do
    test "identical postgres binding is rejected", ctx do
      filter = %{event: :insert, schema: "public", table: "users"}
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", filter)
      force_errored(ctx)

      assert {:error, :duplicate_binding} = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", filter)

      Process.sleep(50)
      assert length(stored_bindings(ctx)) == 1
    end

    test "distinct filters are allowed", ctx do
      :ok =
        Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      force_errored(ctx)

      assert :ok =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :update,
                 schema: "public",
                 table: "posts"
               })

      Process.sleep(50)
      assert length(stored_bindings(ctx)) == 2
    end

    test "one differing field is not a duplicate", ctx do
      base = %{event: :insert, schema: "public", table: "users"}
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", base)

      variants = [
        %{event: :update, schema: "public", table: "users"},
        %{event: :insert, schema: "private", table: "users"},
        %{event: :insert, schema: "public", table: "posts"},
        %{event: :insert, schema: "public", table: "users", filter: "id=eq.1"},
        %{event: :insert, schema: "public", table: "users", select: ["id"]}
      ]

      Enum.each(variants, fn variant ->
        force_errored(ctx)

        assert :ok = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", variant)
      end)

      Process.sleep(50)
      assert length(stored_bindings(ctx)) == 1 + length(variants)
    end

    test "select order is significant (JS join parity)", ctx do
      :ok =
        Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users",
          select: ["a", "b"]
        })

      force_errored(ctx)

      # same columns, different order: not a duplicate
      assert :ok =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :insert,
                 schema: "public",
                 table: "users",
                 select: ["b", "a"]
               })

      force_errored(ctx)

      assert {:error, :duplicate_binding} =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :insert,
                 schema: "public",
                 table: "users",
                 select: ["a", "b"]
               })
    end

    test "select presence vs absence is not a duplicate (either way)", ctx do
      :ok =
        Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      force_errored(ctx)

      assert :ok =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :insert,
                 schema: "public",
                 table: "users",
                 select: ["id"]
               })

      force_errored(ctx)

      # vice versa: existing with select, new without
      with_select = %{event: :update, schema: "public", table: "users", select: ["id"]}
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", with_select)
      force_errored(ctx)

      assert :ok =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :update,
                 schema: "public",
                 table: "users"
               })
    end

    test "nil vs missing keys normalize equal", ctx do
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{event: :insert, schema: "public"})
      force_errored(ctx)

      assert {:error, :duplicate_binding} =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :insert,
                 schema: "public",
                 table: nil,
                 filter: nil
               })
    end

    test "event :all and event \"*\" are the same binding", ctx do
      :ok =
        Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{event: :all, schema: "public", table: "users"})

      force_errored(ctx)

      assert {:error, :duplicate_binding} =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: "*",
                 schema: "public",
                 table: "users"
               })
    end

    test "two Filter structs with the same conditions are duplicates", ctx do
      :ok =
        Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
          event: :update,
          schema: "public",
          table: "users",
          filter: Filter.eq(Filter.new(), "id", 1)
        })

      force_errored(ctx)

      assert {:error, :duplicate_binding} =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :update,
                 schema: "public",
                 table: "users",
                 filter: Filter.eq(Filter.new(), "id", 1)
               })

      force_errored(ctx)

      assert :ok =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :update,
                 schema: "public",
                 table: "users",
                 filter: Filter.lt(Filter.new(), "age", 30)
               })
    end

    test "select: [] still returns {:error, :invalid_select} (normalize precedence)", ctx do
      :ok =
        Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
          event: :insert,
          schema: "public",
          table: "users"
        })

      force_errored(ctx)

      assert {:error, :invalid_select} =
               Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", %{
                 event: :insert,
                 schema: "public",
                 table: "users",
                 select: []
               })

      Process.sleep(50)
      assert length(stored_bindings(ctx)) == 1
    end

    test "broadcast duplicates stay allowed", ctx do
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "broadcast", %{event: "x"})
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "broadcast", %{event: "x"})

      Process.sleep(50)
      {:ok, stored} = Store.find_by_ref(ctx.store, ctx.channel.ref)
      assert length(stored.bindings["broadcast"]) == 2
    end

    test "presence bindings are not deduped", ctx do
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "presence", %{event: "join"})
      force_errored(ctx)

      assert :ok = Registry.subscribe(ctx.registry, ctx.channel, "presence", %{event: "join"})

      Process.sleep(50)
      {:ok, stored} = Store.find_by_ref(ctx.store, ctx.channel.ref)
      assert length(stored.bindings["presence"]) == 2
    end

    test "state errors take precedence over dedup", ctx do
      filter = %{event: :insert, schema: "public", table: "users"}
      :ok = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", filter)
      Process.sleep(50)

      # while :joining, the duplicate hits the state error first
      assert {:error, :already_joining} = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", filter)

      force_errored(ctx)
      assert {:error, :duplicate_binding} = Registry.subscribe(ctx.registry, ctx.channel, "postgres_changes", filter)
    end
  end
end

defmodule Supabase.Realtime.ChannelTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Channel
  alias Supabase.Realtime.Filter

  describe "new/3" do
    test "creates a new channel with default options" do
      client = self()
      channel = Channel.new("test_topic", client)

      assert %Channel{} = channel
      assert channel.topic == "realtime:test_topic"
      assert channel.registry == client
      assert channel.state == :closed
      assert channel.timeout == 10_000
      assert is_map(channel.bindings)
      assert channel.bindings == %{}

      assert channel.params == %{
               config: %{
                 broadcast: %{ack: false, self: false},
                 presence: %{key: ""},
                 private: false
               }
             }

      assert is_binary(channel.ref)
      assert channel.join_ref == nil
    end

    test "creates a channel with custom options" do
      client = self()
      custom_params = %{config: %{private: true}, user_id: 123}
      custom_ref = "custom_ref"

      channel =
        Channel.new("test_topic", client, params: custom_params, timeout: 5000, ref: custom_ref)

      assert channel.topic == "realtime:test_topic"
      assert channel.registry == client
      assert channel.timeout == 5000
      assert channel.ref == custom_ref
      assert channel.params.user_id == 123
      assert channel.params.config.private == true
      assert channel.params.config.broadcast == %{ack: false, self: false}
      assert channel.params.config.presence == %{key: ""}
    end

    test "doesn't modify topic if it already has the realtime prefix" do
      client = self()
      channel = Channel.new("realtime:test_topic", client)

      assert channel.topic == "realtime:test_topic"
    end

    test "creates a private channel with replay config" do
      channel =
        Channel.new("private:room", self(),
          broadcast: [replay: [since: 1_700_000_000, limit: 25]],
          private: true
        )

      config = channel.params.config
      assert config.private == true
      assert config.broadcast.replay == %{since: 1_700_000_000, limit: 25}
    end

    test "creates a private channel with replay without limit" do
      channel =
        Channel.new("private:room", self(),
          broadcast: [replay: [since: 1_700_000_000]],
          private: true
        )

      config = channel.params.config
      assert config.broadcast.replay == %{since: 1_700_000_000}
    end

    test "creates a private channel with replay and other broadcast opts" do
      channel =
        Channel.new("private:room", self(),
          broadcast: [self: true, ack: true, replay: [since: 1_700_000_000]],
          private: true
        )

      config = channel.params.config
      assert config.private == true
      assert config.broadcast.self == true
      assert config.broadcast.ack == true
      assert config.broadcast.replay == %{since: 1_700_000_000}
    end

    test "raises when replay is used on a public channel" do
      assert_raise ArgumentError, ~r/broadcast replay requires a private channel/, fn ->
        Channel.new("public:room", self(), broadcast: [replay: [since: 1_700_000_000]])
      end
    end

    test "creates a private channel via params config" do
      channel =
        Channel.new("room", self(),
          params: %{config: %{private: true}},
          broadcast: [replay: [since: 1_700_000_000]]
        )

      config = channel.params.config
      assert config.private == true
      assert config.broadcast.replay == %{since: 1_700_000_000}
    end
  end

  describe "update_state/2" do
    setup do
      channel = Channel.new("test_topic", self())
      {:ok, channel: channel}
    end

    test "updates the channel state", %{channel: channel} do
      updated = Channel.update_state(channel, :joining)
      assert updated.state == :joining

      updated = Channel.update_state(updated, :joined)
      assert updated.state == :joined

      updated = Channel.update_state(updated, :leaving)
      assert updated.state == :leaving

      updated = Channel.update_state(updated, :closed)
      assert updated.state == :closed

      updated = Channel.update_state(updated, :errored)
      assert updated.state == :errored
    end
  end

  describe "set_join_ref/2" do
    test "sets the join reference" do
      channel = Channel.new("test_topic", self())
      join_ref = "join_ref_123"

      updated = Channel.set_join_ref(channel, join_ref)
      assert updated.join_ref == join_ref
    end
  end

  describe "add_binding/4" do
    setup do
      channel = Channel.new("test_topic", self())
      {:ok, channel: channel}
    end

    test "adds a binding with a map filter", %{channel: channel} do
      filter = %{event: "INSERT", schema: "public", table: "users"}
      callback = fn _ -> :ok end

      updated = Channel.add_binding(channel, "postgres_changes", filter, callback)

      assert [binding] = Map.get(updated.bindings, "postgres_changes")
      assert binding.type == "postgres_changes"
      assert binding.filter == filter
      assert binding.callback == callback
    end

    test "adds a binding with a keyword list filter", %{channel: channel} do
      filter = [event: "UPDATE", schema: "public", table: "users"]
      callback = fn _ -> :ok end

      updated = Channel.add_binding(channel, "postgres_changes", filter, callback)

      assert [binding] = Map.get(updated.bindings, "postgres_changes")
      assert binding.type == "postgres_changes"
      assert binding.filter == %{event: "UPDATE", schema: "public", table: "users"}
      assert binding.callback == callback
    end

    test "adds multiple bindings of the same type", %{channel: channel} do
      filter1 = %{event: "INSERT", schema: "public", table: "users"}
      filter2 = %{event: "UPDATE", schema: "public", table: "users"}

      updated =
        channel
        |> Channel.add_binding("postgres_changes", filter1)
        |> Channel.add_binding("postgres_changes", filter2)

      assert bindings = Map.get(updated.bindings, "postgres_changes")
      assert length(bindings) == 2

      assert [binding2, binding1] = bindings
      assert binding1.filter == filter1
      assert binding2.filter == filter2
    end

    test "adds bindings of different types", %{channel: channel} do
      pg_filter = %{event: "INSERT", schema: "public", table: "users"}
      broadcast_filter = %{event: "new_message"}

      updated =
        channel
        |> Channel.add_binding("postgres_changes", pg_filter)
        |> Channel.add_binding("broadcast", broadcast_filter)

      assert [pg_binding] = Map.get(updated.bindings, "postgres_changes")
      assert [broadcast_binding] = Map.get(updated.bindings, "broadcast")

      assert pg_binding.filter == pg_filter
      assert broadcast_binding.filter == broadcast_filter
    end

    test "sets the id from the filter if present", %{channel: channel} do
      filter = %{id: "custom_id", event: "INSERT"}

      updated = Channel.add_binding(channel, "postgres_changes", filter)

      assert [binding] = Map.get(updated.bindings, "postgres_changes")
      assert binding.id == "custom_id"
    end
  end

  describe "remove_binding/3" do
    setup do
      channel =
        "test_topic"
        |> Channel.new(self())
        |> Channel.add_binding("postgres_changes", %{
          event: "INSERT",
          schema: "public",
          table: "users"
        })
        |> Channel.add_binding("postgres_changes", %{
          event: "UPDATE",
          schema: "public",
          table: "users"
        })
        |> Channel.add_binding("broadcast", %{event: "new_message"})

      {:ok, channel: channel}
    end

    test "removes a specific binding by filter", %{channel: channel} do
      filter = %{event: "INSERT", schema: "public", table: "users"}

      updated = Channel.remove_binding(channel, "postgres_changes", filter)

      assert [binding] = Map.get(updated.bindings, "postgres_changes")
      assert binding.filter.event == "UPDATE"

      assert [_] = Map.get(updated.bindings, "broadcast")
    end

    test "removes a binding using a keyword list filter", %{channel: channel} do
      filter = [event: "UPDATE", schema: "public", table: "users"]

      updated = Channel.remove_binding(channel, "postgres_changes", filter)

      assert [binding] = Map.get(updated.bindings, "postgres_changes")
      assert binding.filter.event == "INSERT"
    end

    test "removes bindings based on partial filter match", %{channel: channel} do
      filter = %{table: "users"}

      updated = Channel.remove_binding(channel, "postgres_changes", filter)

      assert Map.get(updated.bindings, "postgres_changes") == []

      assert [_] = Map.get(updated.bindings, "broadcast")
    end

    test "does nothing if filter doesn't match any bindings", %{channel: channel} do
      filter = %{event: "DELETE", schema: "public", table: "users"}

      updated = Channel.remove_binding(channel, "postgres_changes", filter)

      assert updated.bindings == channel.bindings
    end
  end

  describe "state predicate functions" do
    test "joined?/1 returns true only when state is :joined" do
      channel = Channel.new("test", self())

      assert Channel.joined?(Channel.update_state(channel, :joined)) == true
      assert Channel.joined?(Channel.update_state(channel, :joining)) == false
      assert Channel.joined?(Channel.update_state(channel, :leaving)) == false
      assert Channel.joined?(Channel.update_state(channel, :closed)) == false
      assert Channel.joined?(Channel.update_state(channel, :errored)) == false
    end

    test "joining?/1 returns true only when state is :joining" do
      channel = Channel.new("test", self())

      assert Channel.joining?(Channel.update_state(channel, :joining)) == true
      assert Channel.joining?(Channel.update_state(channel, :joined)) == false
      assert Channel.joining?(Channel.update_state(channel, :leaving)) == false
      assert Channel.joining?(Channel.update_state(channel, :closed)) == false
      assert Channel.joining?(Channel.update_state(channel, :errored)) == false
    end

    test "leaving?/1 returns true only when state is :leaving" do
      channel = Channel.new("test", self())

      assert Channel.leaving?(Channel.update_state(channel, :leaving)) == true
      assert Channel.leaving?(Channel.update_state(channel, :joined)) == false
      assert Channel.leaving?(Channel.update_state(channel, :joining)) == false
      assert Channel.leaving?(Channel.update_state(channel, :closed)) == false
      assert Channel.leaving?(Channel.update_state(channel, :errored)) == false
    end

    test "closed?/1 returns true only when state is :closed" do
      channel = Channel.new("test", self())

      assert Channel.closed?(Channel.update_state(channel, :closed)) == true
      assert Channel.closed?(Channel.update_state(channel, :joined)) == false
      assert Channel.closed?(Channel.update_state(channel, :joining)) == false
      assert Channel.closed?(Channel.update_state(channel, :leaving)) == false
      assert Channel.closed?(Channel.update_state(channel, :errored)) == false
    end

    test "errored?/1 returns true only when state is :errored" do
      channel = Channel.new("test", self())

      assert Channel.errored?(Channel.update_state(channel, :errored)) == true
      assert Channel.errored?(Channel.update_state(channel, :joined)) == false
      assert Channel.errored?(Channel.update_state(channel, :joining)) == false
      assert Channel.errored?(Channel.update_state(channel, :leaving)) == false
      assert Channel.errored?(Channel.update_state(channel, :closed)) == false
    end
  end

  describe "can_push?/1" do
    test "returns true only when channel is joined" do
      channel = Channel.new("test", self())

      assert Channel.can_push?(Channel.update_state(channel, :joined)) == true
      assert Channel.can_push?(Channel.update_state(channel, :joining)) == false
      assert Channel.can_push?(Channel.update_state(channel, :leaving)) == false
      assert Channel.can_push?(Channel.update_state(channel, :closed)) == false
      assert Channel.can_push?(Channel.update_state(channel, :errored)) == false
    end
  end

  describe "private?/1" do
    test "C1: false by default" do
      refute Channel.private?(Channel.new("room", self()))
    end

    test "C1: true when created with private: true (opts path)" do
      assert Channel.private?(Channel.new("room", self(), private: true))
    end

    test "C1: true when created with params config private (params path)" do
      channel = Channel.new("room", self(), params: %{config: %{private: true}})
      assert Channel.private?(channel)
    end
  end

  describe "normalize_filter/2" do
    test "C2: converts keyword lists to maps" do
      assert Channel.normalize_filter("postgres_changes", event: "INSERT", schema: "public") ==
               {:ok, %{event: "INSERT", schema: "public"}}
    end

    test "C2: normalizes event :all to *" do
      assert Channel.normalize_filter("postgres_changes", %{event: :all, schema: "public"}) ==
               {:ok, %{event: "*", schema: "public"}}
    end

    test "C2: serializes a %Filter{} given as :filter" do
      filter =
        Filter.new()
        |> Filter.eq("id", 1)
        |> Filter.lt("age", 30)

      assert Channel.normalize_filter("postgres_changes", %{
               event: "UPDATE",
               schema: "public",
               table: "users",
               filter: filter
             }) ==
               {:ok, %{event: "UPDATE", schema: "public", table: "users", filter: "id=eq.1,age=lt.30"}}
    end

    test "C2: valid select passes through" do
      assert Channel.normalize_filter("postgres_changes", %{
               event: "*",
               schema: "public",
               table: "users",
               select: ["id", "first_name"]
             }) ==
               {:ok, %{event: "*", schema: "public", table: "users", select: ["id", "first_name"]}}
    end

    test "C2: empty select is rejected" do
      assert Channel.normalize_filter("postgres_changes", %{event: "*", schema: "public", select: []}) ==
               {:error, :invalid_select}
    end

    test "C2: non-list select is rejected" do
      assert Channel.normalize_filter("postgres_changes", %{event: "*", schema: "public", select: "id"}) ==
               {:error, :invalid_select}
    end

    test "C2: select with non-binary elements is rejected" do
      assert Channel.normalize_filter("postgres_changes", %{event: "*", schema: "public", select: ["id", 42]}) ==
               {:error, :invalid_select}
    end

    test "C2: absent select passes through" do
      assert Channel.normalize_filter("postgres_changes", %{event: "*", schema: "public"}) ==
               {:ok, %{event: "*", schema: "public"}}
    end

    test "C2: other types skip select validation" do
      assert Channel.normalize_filter("broadcast", %{event: "new_message", select: []}) ==
               {:ok, %{event: "new_message", select: []}}
    end
  end

  describe "same_postgres_filter?/2" do
    # all inputs below are normalize_filter/2 output (Filter built to a
    # string, select already validated), per the function's precondition
    test "identical normalized filters are duplicates" do
      filter = %{event: "INSERT", schema: "public", table: "users", filter: "id=eq.1"}

      assert Channel.same_postgres_filter?(filter, %{event: "INSERT", schema: "public", table: "users", filter: "id=eq.1"})
    end

    test "each single-field difference is not a duplicate" do
      base = %{event: "INSERT", schema: "public", table: "users", filter: "id=eq.1", select: ["id"]}

      refute Channel.same_postgres_filter?(base, %{base | event: "UPDATE"})
      refute Channel.same_postgres_filter?(base, %{base | schema: "private"})
      refute Channel.same_postgres_filter?(base, %{base | table: "posts"})
      refute Channel.same_postgres_filter?(base, %{base | filter: "id=eq.2"})
      refute Channel.same_postgres_filter?(base, %{base | select: ["name"]})
    end

    test "nil vs missing keys compare equal" do
      assert Channel.same_postgres_filter?(
               %{event: "INSERT", schema: "public"},
               %{event: "INSERT", schema: "public", table: nil, filter: nil, select: nil}
             )
    end

    test "select is order-sensitive (JS join parity)" do
      base = %{event: "*", schema: "public", select: ["a", "b"]}

      assert Channel.same_postgres_filter?(base, %{base | select: ["a", "b"]})
      refute Channel.same_postgres_filter?(base, %{base | select: ["b", "a"]})
    end

    test "select presence vs absence is not a duplicate" do
      base = %{event: "*", schema: "public"}

      # an explicit nil select is the same binding as an absent one
      assert Channel.same_postgres_filter?(base, Map.put(base, :select, nil))

      with_select = Map.put(base, :select, ["id"])
      refute Channel.same_postgres_filter?(base, with_select)
      refute Channel.same_postgres_filter?(with_select, base)
    end

    test "id is not compared: two maps differing only in id are duplicates" do
      assert Channel.same_postgres_filter?(
               %{event: "INSERT", schema: "public", table: "users", id: 1},
               %{event: "INSERT", schema: "public", table: "users", id: 106_243_155}
             )
    end
  end
end

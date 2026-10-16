defmodule Supabase.Realtime.FilterTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.Filter

  describe "serialization" do
    test "F1: joins conditions with commas in insertion order" do
      filter = Filter.new() |> Filter.eq("id", 1) |> Filter.lt("age", 30)
      assert Filter.build(filter) == "id=eq.1,age=lt.30"
    end

    test "F2: every builder works without an explicit first argument" do
      filter = "id" |> Filter.eq(1) |> Filter.lt("age", 30)
      assert Filter.build(filter) == "id=eq.1,age=lt.30"
    end

    test "F3: every scalar operator emits its wire prefix" do
      filter =
        Filter.new()
        |> Filter.neq("a", 1)
        |> Filter.gt("b", 2)
        |> Filter.gte("c", 3)
        |> Filter.lt("d", 4)
        |> Filter.lte("e", 5)
        |> Filter.like("title", "%foo%")
        |> Filter.ilike("title2", "%bar%")
        |> Filter.match("name", "^a")
        |> Filter.imatch("name2", "^b")

      assert Filter.build(filter) ==
               "a=neq.1,b=gt.2,c=gte.3,d=lt.4,e=lte.5,title=like.%foo%," <>
                 "title2=ilike.%bar%,name=match.^a,name2=imatch.^b"
    end

    test "F4: nil, booleans and numbers serialize without quoting" do
      assert Filter.build(Filter.eq("deleted_at", nil)) == "deleted_at=eq.null"
      assert Filter.build(Filter.eq("active", true)) == "active=eq.true"
      assert Filter.build(Filter.eq("count", 42)) == "count=eq.42"
      assert Filter.build(Filter.eq("score", 1.5)) == "score=eq.1.5"
    end

    test "F5: an empty builder builds an empty string" do
      assert Filter.build(Filter.new()) == ""
    end

    test "F6: String.Chars matches build/1" do
      filter = Filter.new() |> Filter.eq("id", 1) |> Filter.lt("age", 30)

      assert to_string(filter) == Filter.build(filter)
      assert "#{filter}" == "id=eq.1,age=lt.30"
    end

    test "F7: Inspect renders the built string" do
      filter = Filter.new() |> Filter.eq("id", 1) |> Filter.lt("age", 30)
      assert inspect(filter) == ~s{#Supabase.Realtime.Filter<"id=eq.1,age=lt.30">}
    end
  end

  describe "quoting" do
    test "F8: comma is quoted" do
      assert Filter.build(Filter.eq("name", "a,b")) == "name=eq.\"a,b\""
    end

    test "F9: parens are quoted" do
      assert Filter.build(Filter.eq("name", "a(b)c")) == "name=eq.\"a(b)c\""
    end

    test "F10: double quotes are escaped" do
      assert Filter.build(Filter.eq("note", ~s{he said "hi"})) ==
               ~s(note=eq."he said \\"hi\\"")
    end

    test "F11: backslashes are doubled" do
      assert Filter.build(Filter.eq("path", "a\\b")) == "path=eq.\"a\\\\b\""
    end

    test "F12: quotes AND backslashes, backslashes doubled first (escaping order regression)" do
      assert Filter.build(Filter.eq("col", ~s{a"b\\c})) == "col=eq.\"a\\\"b\\\\c\""
    end

    test "F13: surrounding whitespace is quoted, inner whitespace is not" do
      assert Filter.build(Filter.eq("name", " padded ")) == "name=eq.\" padded \""
      assert Filter.build(Filter.eq("name", " x")) == "name=eq.\" x\""
      assert Filter.build(Filter.eq("name", "x ")) == "name=eq.\"x \""
      assert Filter.build(Filter.eq("name", "a b")) == "name=eq.a b"
    end

    test "F14: clean values stay bare" do
      assert Filter.build(Filter.eq("name", "abc")) == "name=eq.abc"
    end
  end

  describe "within/3" do
    test "F15: serializes in.(a,b)" do
      assert Filter.build(Filter.within("status", ["active", "pending"])) ==
               "status=in.(active,pending)"
    end

    test "F16: dedups keeping first occurrences" do
      assert Filter.build(Filter.within("status", ["b", "a", "b"])) == "status=in.(b,a)"
    end

    test "F17: quotes items individually" do
      assert Filter.build(Filter.within("name", ["a,b", "c"])) == "name=in.(\"a,b\",c)"
    end

    test "F18: accepts a single item" do
      assert Filter.build(Filter.within("status", ["active"])) == "status=in.(active)"
    end

    test "F19: empty list raises ArgumentError" do
      assert_raise ArgumentError, ~r/at least one value/, fn ->
        Filter.build(Filter.within("status", []))
      end
    end

    test "F20: nil element raises ArgumentError" do
      assert_raise ArgumentError, ~r/does not accept nil/, fn ->
        Filter.build(Filter.within("status", [nil]))
      end
    end

    test "F21: non-scalar element raises ArgumentError" do
      assert_raise ArgumentError, ~r/only string, number or boolean/, fn ->
        Filter.build(Filter.within("status", [%{}]))
      end
    end

    test "F22: non-list values raise a guard error" do
      assert_raise FunctionClauseError, fn ->
        apply(Filter, :within, ["status", "active"])
      end
    end
  end

  describe "is/3 and is_distinct/3" do
    test "F23: keyword values pass through unquoted" do
      assert Filter.build(Filter.is("deleted_at", nil)) == "deleted_at=is.null"
      assert Filter.build(Filter.is("active", true)) == "active=is.true"
      assert Filter.build(Filter.is("active", false)) == "active=is.false"
      assert Filter.build(Filter.is("status", "null")) == "status=is.null"
      assert Filter.build(Filter.is("status", "true")) == "status=is.true"
      assert Filter.build(Filter.is("status", "false")) == "status=is.false"
      assert Filter.build(Filter.is("status", "unknown")) == "status=is.unknown"
    end

    test "F24: invalid is values raise ArgumentError" do
      assert_raise ArgumentError, ~r/invalid `is` value/, fn ->
        Filter.build(Filter.is("status", "weird"))
      end
    end

    test "F25: is_distinct serializes the isdistinct operator" do
      assert Filter.build(Filter.is_distinct("name", nil)) == "name=isdistinct.null"
      assert Filter.build(Filter.is_distinct("status", "active")) == "status=isdistinct.active"
    end
  end

  describe "negate/4" do
    test "F26: negates in" do
      assert Filter.build(Filter.negate("status", :in, ["draft", "archived"])) ==
               "status=not.in.(draft,archived)"
    end

    test "F27: negates is" do
      assert Filter.build(Filter.negate("deleted_at", :is, nil)) == "deleted_at=not.is.null"
    end

    test "F28: negates scalar operators" do
      assert Filter.build(Filter.negate("amount", :gt, 100)) == "amount=not.gt.100"
    end

    test "F29: chains with commas" do
      filter = Filter.new() |> Filter.negate("id", :eq, 1) |> Filter.negate("age", :lt, 30)
      assert Filter.build(filter) == "id=not.eq.1,age=not.lt.30"
    end

    test "F30: unknown operators raise ArgumentError listing valid ones" do
      assert_raise ArgumentError, ~r/invalid Realtime filter operator :fts/, fn ->
        Filter.negate("col", :fts, "x")
      end
    end
  end

  describe "guard errors" do
    # the deliberate bad calls go through apply/3 so the gradual type checker
    # does not flag them: these test RUNTIME guards, not the static contract
    test "non-binary columns raise FunctionClauseError" do
      assert_raise FunctionClauseError, fn -> apply(Filter, :eq, [42, 1]) end
      assert_raise FunctionClauseError, fn -> apply(Filter, :is_distinct, [nil, nil]) end
    end

    test "atom values are rejected" do
      assert_raise FunctionClauseError, fn -> apply(Filter, :eq, ["col", :atom]) end
    end

    test "invalid is value via negate still raises ArgumentError" do
      assert_raise ArgumentError, ~r/invalid `is` value/, fn ->
        Filter.build(Filter.negate("status", :is, "weird"))
      end
    end

    test "negate rejects non-scalar values for scalar operators" do
      assert_raise FunctionClauseError, fn ->
        apply(Filter, :negate, ["col", :eq, %{}])
      end
    end
  end
end

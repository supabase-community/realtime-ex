defmodule Supabase.Realtime.PostgresTypesTest do
  use ExUnit.Case, async: true

  alias Supabase.Realtime.PostgresTypes

  describe "transform/2" do
    test "returns nil for nil record" do
      assert PostgresTypes.transform(nil, []) == nil
    end

    test "returns record unchanged with empty columns" do
      record = %{"name" => "test"}
      assert PostgresTypes.transform(record, []) == record
    end

    test "casts boolean types" do
      columns = [%{"name" => "active", "type" => "bool"}]
      assert PostgresTypes.transform(%{"active" => "true"}, columns) == %{"active" => true}
      assert PostgresTypes.transform(%{"active" => "t"}, columns) == %{"active" => true}
      assert PostgresTypes.transform(%{"active" => "false"}, columns) == %{"active" => false}
      assert PostgresTypes.transform(%{"active" => "f"}, columns) == %{"active" => false}
    end

    test "casts integer types" do
      columns = [%{"name" => "count", "type" => "int4"}]
      assert PostgresTypes.transform(%{"count" => "42"}, columns) == %{"count" => 42}
    end

    test "casts bigint" do
      columns = [%{"name" => "id", "type" => "int8"}]
      assert PostgresTypes.transform(%{"id" => "9999999999"}, columns) == %{"id" => 9_999_999_999}
    end

    test "casts float types" do
      columns = [%{"name" => "price", "type" => "float8"}]
      assert PostgresTypes.transform(%{"price" => "19.99"}, columns) == %{"price" => 19.99}
    end

    test "casts numeric as integer" do
      columns = [%{"name" => "amount", "type" => "numeric"}]
      assert PostgresTypes.transform(%{"amount" => "100"}, columns) == %{"amount" => 100}
    end

    test "casts numeric as float" do
      columns = [%{"name" => "amount", "type" => "numeric"}]
      assert PostgresTypes.transform(%{"amount" => "100.50"}, columns) == %{"amount" => 100.50}
    end

    test "casts json/jsonb" do
      columns = [%{"name" => "data", "type" => "jsonb"}]

      assert PostgresTypes.transform(%{"data" => ~s({"key":"value"})}, columns) == %{
               "data" => %{"key" => "value"}
             }
    end

    test "casts timestamp" do
      columns = [%{"name" => "created_at", "type" => "timestamptz"}]
      result = PostgresTypes.transform(%{"created_at" => "2024-01-15T10:30:00Z"}, columns)
      assert %DateTime{} = result["created_at"]
    end

    test "casts date" do
      columns = [%{"name" => "birthday", "type" => "date"}]
      result = PostgresTypes.transform(%{"birthday" => "2024-01-15"}, columns)
      assert result["birthday"] == ~D[2024-01-15]
    end

    test "casts time" do
      columns = [%{"name" => "start_time", "type" => "time"}]
      result = PostgresTypes.transform(%{"start_time" => "10:30:00"}, columns)
      assert result["start_time"] == ~T[10:30:00]
    end

    test "casts array types" do
      columns = [%{"name" => "tags", "type" => "_text"}]
      result = PostgresTypes.transform(%{"tags" => "{hello,world}"}, columns)
      assert result["tags"] == ["hello", "world"]
    end

    test "casts integer array" do
      columns = [%{"name" => "ids", "type" => "_int4"}]
      result = PostgresTypes.transform(%{"ids" => "{1,2,3}"}, columns)
      assert result["ids"] == [1, 2, 3]
    end

    test "handles nil values" do
      columns = [%{"name" => "name", "type" => "text"}]
      assert PostgresTypes.transform(%{"name" => nil}, columns) == %{"name" => nil}
    end

    test "preserves unknown types" do
      columns = [%{"name" => "geo", "type" => "geometry"}]
      assert PostgresTypes.transform(%{"geo" => "POINT(0 0)"}, columns) == %{"geo" => "POINT(0 0)"}
    end

    test "transforms multiple columns" do
      columns = [
        %{"name" => "id", "type" => "int4"},
        %{"name" => "name", "type" => "text"},
        %{"name" => "active", "type" => "bool"}
      ]

      record = %{"id" => "1", "name" => "test", "active" => "true"}
      result = PostgresTypes.transform(record, columns)

      assert result == %{"id" => 1, "name" => "test", "active" => true}
    end
  end
end

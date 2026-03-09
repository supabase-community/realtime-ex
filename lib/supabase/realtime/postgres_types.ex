defmodule Supabase.Realtime.PostgresTypes do
  @moduledoc """
  Transforms postgres_changes payload column values from strings to native Elixir types.

  ## Supported Types

  | Postgres type                         | Elixir type       |
  |---------------------------------------|-------------------|
  | `bool`, `boolean`                     | `boolean()`       |
  | `int2`, `int4`, `int8`, `smallint`,   | `integer()`       |
  |   `integer`, `bigint`                 |                   |
  | `float4`, `float8`, `real`, `double`  | `float()`         |
  | `numeric`                             | `integer()` or `float()` |
  | `json`, `jsonb`                       | decoded term      |
  | `timestamp`, `timestamptz`            | `DateTime.t()`    |
  | `date`                                | `Date.t()`        |
  | `time`, `timetz`                      | `Time.t()`        |
  | `uuid`                                | `String.t()`      |
  | `text`, `varchar`, `char`, `name`,    | `String.t()`      |
  |   `citext`                            |                   |
  | Array types (e.g. `_int4`, `_text`)   | `list()` of the inner type |

  Any type not listed above is returned as-is.

  ## Examples

      columns = [
        %{"name" => "id", "type" => "int8"},
        %{"name" => "active", "type" => "bool"},
        %{"name" => "score", "type" => "float8"}
      ]

      record = %{"id" => "42", "active" => "true", "score" => "9.5"}

      PostgresTypes.transform(record, columns)
      #=> %{"id" => 42, "active" => true, "score" => 9.5}
  """

  @doc """
  Transforms a record map using column metadata from the event payload.

  ## Parameters

  * `record` - The record map with string values
  * `columns` - List of column metadata maps with "name" and "type" keys
  """
  @spec transform(map() | nil, list(map())) :: map() | nil
  def transform(nil, _columns), do: nil
  def transform(record, []), do: record

  def transform(record, columns) when is_map(record) and is_list(columns) do
    type_map =
      Map.new(columns, fn col ->
        {col["name"], col["type"]}
      end)

    Map.new(record, fn {key, value} ->
      case Map.get(type_map, key) do
        nil -> {key, value}
        type -> {key, cast(value, type)}
      end
    end)
  end

  defp cast(nil, _type), do: nil

  defp cast(value, type) when type in ~w(bool boolean) do
    value in [true, "t", "true", "1"]
  end

  defp cast(value, type) when type in ~w(int2 int4 int8 smallint integer bigint) do
    case Integer.parse(to_string(value)) do
      {int, ""} -> int
      _ -> value
    end
  end

  defp cast(value, type) when type in ~w(float4 float8 real double) do
    case Float.parse(to_string(value)) do
      {float, ""} -> float
      _ -> value
    end
  end

  defp cast(value, "numeric") do
    str = to_string(value)

    if String.contains?(str, ".") do
      case Float.parse(str) do
        {f, ""} -> f
        _ -> value
      end
    else
      case Integer.parse(str) do
        {i, ""} -> i
        _ -> value
      end
    end
  end

  defp cast(value, type) when type in ~w(json jsonb) do
    case Jason.decode(to_string(value)) do
      {:ok, decoded} -> decoded
      _ -> value
    end
  end

  defp cast(value, type) when type in ~w(timestamp timestamptz) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, dt, _} -> dt
      _ -> value
    end
  end

  defp cast(value, "date") do
    case Date.from_iso8601(to_string(value)) do
      {:ok, date} -> date
      _ -> value
    end
  end

  defp cast(value, type) when type in ~w(time timetz) do
    case Time.from_iso8601(to_string(value)) do
      {:ok, time} -> time
      _ -> value
    end
  end

  defp cast(value, "uuid"), do: to_string(value)

  defp cast(value, type) when type in ~w(text varchar char name citext), do: to_string(value)

  # Array types (e.g. _int4, _text, _bool)
  defp cast(value, "_" <> inner_type) when is_binary(value) do
    value
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> String.split(",", trim: true)
    |> Enum.map(&cast(String.trim(&1), inner_type))
  end

  defp cast(value, _type), do: value
end

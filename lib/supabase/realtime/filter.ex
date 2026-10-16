defmodule Supabase.Realtime.Filter do
  @moduledoc """
  Fluent builder for postgres_changes `filter` strings.

  Each function appends one `column=operator.value` condition; multiple
  conditions are joined with commas, which the Realtime server applies as
  AND. Values containing reserved characters (`,` `(` `)` `"` `\\`) or
  surrounding whitespace are double-quoted and escaped the way PostgREST
  does. An empty builder builds `""` (the server treats it as "no filter").

  Pass the built string (or the struct, which `Realtime.on/3` serializes
  automatically) as the `:filter` option of a `postgres_changes` binding.

  ## Example

      Supabase.Realtime.Filter.new()
      |> Supabase.Realtime.Filter.eq("id", 1)
      |> Supabase.Realtime.Filter.lt("age", 30)
      |> Supabase.Realtime.Filter.build()
      #=> "id=eq.1,age=lt.30"
  """

  alias Supabase.Realtime.Filter

  defstruct conditions: []

  @type t :: %__MODULE__{conditions: [String.t()]}
  @type value :: String.t() | number() | boolean() | nil
  @type in_value :: String.t() | number() | boolean()

  # The accepted binary values are exactly "null" | "true" | "false" |
  # "unknown"; Elixir typespecs cannot express string-literal unions, so the
  # closed set is documented here and enforced at runtime by `is/3`.
  @type is_value :: nil | boolean() | binary()

  @type operator ::
          :eq | :neq | :gt | :gte | :lt | :lte | :in | :like | :ilike | :match | :imatch | :is | :isdistinct

  @scalar_operators [:eq, :neq, :gt, :gte, :lt, :lte, :like, :ilike, :match, :imatch, :isdistinct]
  @operators [:in, :is | @scalar_operators]

  # Reserved characters that force PostgREST-style quoting: `,()` (which the
  # server reads as condition/list delimiters) plus `"`/`\` (escaped inside
  # quotes).
  @reserved [",", "(", ")", "\"", "\\"]

  defguardp is_scalar(value)
            when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value)

  @doc """
  Builder functions take the filter as an optional first argument, so both
  `Filter.new() |> Filter.eq("id", 1)` and `Filter.eq("id", 1) |> ...` work.

  Invalid input raises: a guard failure (`FunctionClauseError`) for
  non-binary columns and non-scalar values, an `ArgumentError` for the cases
  documented per function. This mirrors realtime-js, which throws on the
  same inputs.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Match rows where `column` equals `value` (`column=eq.value`)."
  @spec eq(t(), String.t(), value()) :: t()
  def eq(filter \\ new(), column, value) when is_binary(column) and is_scalar(value) do
    add(filter, column, :eq, value, false)
  end

  @doc "Match rows where `column` does not equal `value` (`column=neq.value`)."
  @spec neq(t(), String.t(), value()) :: t()
  def neq(filter \\ new(), column, value) when is_binary(column) and is_scalar(value) do
    add(filter, column, :neq, value, false)
  end

  @doc "Match rows where `column` is greater than `value` (`column=gt.value`)."
  @spec gt(t(), String.t(), value()) :: t()
  def gt(filter \\ new(), column, value) when is_binary(column) and is_scalar(value) do
    add(filter, column, :gt, value, false)
  end

  @doc "Match rows where `column` is greater than or equal to `value` (`column=gte.value`)."
  @spec gte(t(), String.t(), value()) :: t()
  def gte(filter \\ new(), column, value) when is_binary(column) and is_scalar(value) do
    add(filter, column, :gte, value, false)
  end

  @doc "Match rows where `column` is less than `value` (`column=lt.value`)."
  @spec lt(t(), String.t(), value()) :: t()
  def lt(filter \\ new(), column, value) when is_binary(column) and is_scalar(value) do
    add(filter, column, :lt, value, false)
  end

  @doc "Match rows where `column` is less than or equal to `value` (`column=lte.value`)."
  @spec lte(t(), String.t(), value()) :: t()
  def lte(filter \\ new(), column, value) when is_binary(column) and is_scalar(value) do
    add(filter, column, :lte, value, false)
  end

  @doc """
  Match rows where `column` is one of `values` (`column=in.(a,b)`).

  Requires at least one value (raises `ArgumentError` otherwise); duplicates
  are removed keeping first occurrences. `nil` and non-scalar elements raise
  `ArgumentError` (`IN (null)` never matches in SQL; use `is/3` or `negate/4`
  with `:is` for null checks). An element containing a reserved character is
  double-quoted individually (`in.("a,b",c)`), so commas inside an element
  are preserved.
  """
  @spec within(t(), String.t(), [in_value()]) :: t()
  def within(filter \\ new(), column, values) when is_binary(column) and is_list(values) do
    validate_in_values!(column, values)
    add(filter, column, :in, values, false)
  end

  @doc "Match rows where `column` matches the case-sensitive `pattern` (`column=like.pattern`)."
  @spec like(t(), String.t(), pattern :: String.t()) :: t()
  def like(filter \\ new(), column, pattern) when is_binary(column) and is_binary(pattern) do
    add(filter, column, :like, pattern, false)
  end

  @doc "Match rows where `column` matches the case-insensitive `pattern` (`column=ilike.pattern`)."
  @spec ilike(t(), String.t(), pattern :: String.t()) :: t()
  def ilike(filter \\ new(), column, pattern) when is_binary(column) and is_binary(pattern) do
    add(filter, column, :ilike, pattern, false)
  end

  @doc "Match rows where `column` matches the POSIX regex `pattern` (`column=match.pattern`)."
  @spec match(t(), String.t(), pattern :: String.t()) :: t()
  def match(filter \\ new(), column, pattern) when is_binary(column) and is_binary(pattern) do
    add(filter, column, :match, pattern, false)
  end

  @doc "Match rows where `column` matches the case-insensitive POSIX regex `pattern` (`column=imatch.pattern`)."
  @spec imatch(t(), String.t(), pattern :: String.t()) :: t()
  def imatch(filter \\ new(), column, pattern) when is_binary(column) and is_binary(pattern) do
    add(filter, column, :imatch, pattern, false)
  end

  @doc """
  Match rows where `column` `IS` the given value (`column=is.null`).

  Accepts `nil`, a boolean, or the keywords `"null"`, `"true"`, `"false"`
  and `"unknown"`. Any other value raises `ArgumentError`. `is` values are
  never quoted.
  """
  @spec is(t(), String.t(), is_value()) :: t()
  def is(filter \\ new(), column, value) when is_binary(column) do
    add(filter, column, :is, value, false)
  end

  @doc "Match rows where `column` is distinct from `value` (`column=isdistinct.value`). NULL-safe inequality."
  @spec is_distinct(t(), String.t(), value()) :: t()
  def is_distinct(filter \\ new(), column, value) when is_binary(column) and is_scalar(value) do
    add(filter, column, :isdistinct, value, false)
  end

  @doc """
  Negate any operator with the `not.` prefix (`column=not.operator.value`).

  `:in` takes a list, `:is` takes an `IS` keyword/boolean/null, every other
  operator takes a scalar value. Raises `ArgumentError` for an operator
  outside `t:operator/0`.
  """
  @spec negate(t(), String.t(), operator(), value() | [in_value()]) :: t()
  def negate(filter \\ new(), column, operator, value)

  def negate(filter, column, operator, value)
      when is_binary(column) and operator in @scalar_operators and is_scalar(value) do
    add(filter, column, operator, value, true)
  end

  def negate(filter, column, :in, values) when is_binary(column) and is_list(values) do
    validate_in_values!(column, values)
    add(filter, column, :in, values, true)
  end

  def negate(filter, column, :is, value) when is_binary(column) do
    add(filter, column, :is, value, true)
  end

  def negate(_filter, _column, operator, _value) when operator not in @operators do
    raise ArgumentError,
          "invalid Realtime filter operator #{inspect(operator)}; " <>
            "valid operators: #{inspect(@operators)}"
  end

  @doc """
  Serializes all conditions into the comma-separated (AND) filter string.

  Conditions are joined by commas, which the server applies as `AND`. An
  empty builder builds `""`, which the server treats as no filter.
  """
  @spec build(t()) :: String.t()
  def build(%__MODULE__{conditions: conditions}) do
    Enum.join(Enum.reverse(conditions), ",")
  end

  # Private serialization core: exact port of
  # `RealtimePostgresFilterBuilder.ts`. The escaping order is load-bearing:
  # backslashes are doubled BEFORE quotes are escaped.

  defp add(%__MODULE__{conditions: conditions}, column, operator, value, negate?) when is_binary(column) do
    prefix = if negate?, do: "not.", else: ""

    %__MODULE__{
      conditions: ["#{column}=#{prefix}#{serialize(operator, value)}" | conditions]
    }
  end

  defp serialize(:in, values) when is_list(values) do
    "in.(" <> Enum.map_join(serialize_in_values(values), ",", &serialize_scalar/1) <> ")"
  end

  defp serialize(:is, value), do: "is." <> serialize_is(value)
  defp serialize(operator, value), do: "#{operator}." <> serialize_scalar(value)

  defp serialize_in_values([]), do: raise(ArgumentError, "Realtime `in` filter requires at least one value")

  # JS: Array.from(new Set(values)), insertion order kept
  defp serialize_in_values(values), do: Enum.uniq(values)

  defp validate_in_values!(column, values) do
    Enum.each(values, fn
      value when is_binary(value) or is_number(value) or is_boolean(value) ->
        :ok

      nil ->
        raise ArgumentError,
              "Realtime `in` filter on `#{column}` does not accept nil values; " <>
                "use `is` (or `negate` with `:is`) for null checks"

      other ->
        raise ArgumentError,
              "Realtime `in` filter on `#{column}` accepts only string, number " <>
                "or boolean values, got: #{inspect(other)}"
    end)
  end

  defp serialize_scalar(nil), do: "null"
  defp serialize_scalar(value), do: maybe_quote(to_string(value))

  defp maybe_quote(value) do
    if String.contains?(value, @reserved) or value != String.trim(value) do
      quote_value(value)
    else
      value
    end
  end

  defp quote_value(value) do
    escaped =
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp serialize_is(nil), do: "null"

  defp serialize_is(value) when value in [true, false, "null", "true", "false", "unknown"], do: to_string(value)

  defp serialize_is(value), do: raise(ArgumentError, "invalid `is` value: #{inspect(value)}")

  defimpl String.Chars do
    def to_string(filter), do: Filter.build(filter)
  end

  defimpl Inspect do
    def inspect(filter, _opts) do
      "#Supabase.Realtime.Filter<" <> inspect(Filter.build(filter)) <> ">"
    end
  end
end

defmodule TeleScope.EventName do
  @moduledoc """
  Symbolic telemetry event names ("patterns").

  Static analysis cannot always know an event name completely. A pattern is a
  list of *parts*:

    * `atom` - a known segment, e.g. `:phoenix`
    * `{:var, origin}` - exactly one unknown segment
    * `{:splice, origin}` - zero or more unknown segments (e.g. `prefix ++ [:query]`)

  `origin` is `:unknown` or `{:param, index}` when the value flows from the
  enclosing function's parameter (used for wrapper resolution). Patterns that
  still contain `{:param, _}` origins are *wrapper templates*; they are resolved
  at the wrapper's call sites and reported as unknown otherwise.

  Classification:

    * `:literal`  - every part is an atom
    * `:partial`  - at least one known atom and at least one unknown part
    * `:dynamic`  - no known atoms at all
    * `:invalid`  - statically provably not a valid event name
  """

  @type origin :: :unknown | {:param, non_neg_integer()}
  @type part :: atom() | {:var, origin()} | {:splice, origin()}
  @type pattern :: [part()] | :invalid
  @type classification :: :literal | :partial | :dynamic | :invalid

  @doc "Classifies a pattern."
  @spec classify(pattern()) :: classification()
  def classify(:invalid), do: :invalid
  def classify([]), do: :invalid

  def classify(parts) do
    {known, unknown} = Enum.split_with(parts, &is_atom/1)

    cond do
      unknown == [] -> :literal
      known == [] -> :dynamic
      true -> :partial
    end
  end

  @doc "Returns true if `pattern` is fully known."
  def literal?(pattern), do: classify(pattern) == :literal

  @doc "Returns true when the pattern still depends on function parameters."
  def parametric?(:invalid), do: false

  def parametric?(parts) do
    Enum.any?(parts, fn
      {_, {:param, _}} -> true
      _ -> false
    end)
  end

  @doc "Replaces every parameter origin with `:unknown`."
  def forget_params(:invalid), do: :invalid

  def forget_params(parts) do
    Enum.map(parts, fn
      {kind, {:param, _}} -> {kind, :unknown}
      other -> other
    end)
  end

  @doc """
  Does the concrete event `name` match `pattern`?

      iex> TeleScope.EventName.matches?([{:splice, :unknown}, :query], [:my_app, :repo, :query])
      true
      iex> TeleScope.EventName.matches?([:finch, {:var, :unknown}, :stop], [:finch, :request, :stop])
      true
      iex> TeleScope.EventName.matches?([:finch, {:var, :unknown}, :stop], [:finch, :stop])
      false
  """
  @spec matches?(pattern(), [atom()]) :: boolean()
  def matches?(:invalid, _name), do: false
  def matches?([], []), do: true
  def matches?([], _), do: false
  def matches?([{:splice, _} | rest], name), do: splice_match?(rest, name)
  def matches?([{:var, _} | rest], [_ | name]), do: matches?(rest, name)
  def matches?([a | rest], [a | name]) when is_atom(a), do: matches?(rest, name)
  def matches?(_, _), do: false

  defp splice_match?(rest, name) do
    matches?(rest, name) or
      case name do
        [_ | tail] -> splice_match?(rest, tail)
        [] -> false
      end
  end

  @doc "Known leading atoms of a pattern (useful for grouping/prefix search)."
  def known_prefix(:invalid), do: []
  def known_prefix(parts), do: Enum.take_while(parts, &is_atom/1)

  @doc "Human readable representation, e.g. `[:finch, *, :stop]` / `[** , :query]`."
  @spec format(pattern() | [atom()]) :: String.t()
  def format(:invalid), do: "<invalid>"

  def format(parts) do
    inner =
      Enum.map_join(parts, ", ", fn
        a when is_atom(a) -> inspect(a)
        {:var, {:param, i}} -> "$arg#{i}"
        {:var, _} -> "*"
        {:splice, {:param, i}} -> "$arg#{i}..."
        {:splice, _} -> "**"
      end)

    "[" <> inner <> "]"
  end

  @doc "Dotted string form used by Telemetry.Metrics, e.g. `phoenix.endpoint.stop`."
  def dotted(name) when is_list(name), do: Enum.map_join(name, ".", &Atom.to_string/1)

  @doc "Is `term` a valid concrete telemetry event name (non-empty list of atoms)?"
  def valid_name?([_ | _] = name), do: atoms?(name)
  def valid_name?(_), do: false

  # handles improper lists (Enum.all?/2 would raise on them)
  defp atoms?([]), do: true
  defp atoms?([a | rest]) when is_atom(a), do: atoms?(rest)
  defp atoms?(_), do: false

  @doc """
  Splits span events into `{prefix, suffix}` when the last segment is one of
  `:start`, `:stop`, `:exception`.
  """
  def span_split(name) when is_list(name) and name != [] do
    case List.last(name) do
      suffix when suffix in [:start, :stop, :exception] ->
        {:ok, Enum.drop(name, -1), suffix}

      _ ->
        :error
    end
  end

  def span_split(_), do: :error
end

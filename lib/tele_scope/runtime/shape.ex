defmodule TeleScope.Runtime.Shape do
  @moduledoc """
  Converts measurement/metadata maps into *shapes*: key -> type tag.

  Values are never retained. Only:

    * atom keys (non-atom keys are collapsed into a single
      `{:__non_atom_keys__, :present}` entry because string keys are frequently user
      data such as header names or emails)
    * a type tag per value; structs keep their module identity
      (`{:struct, Plug.Conn}`) but none of their fields

  Shapes are computed at depth 1 on purpose: nested maps are tagged `:map`.
  Recursing would multiply the per-event cost and the number of distinct
  shapes (see LIMITATIONS.md).
  """

  @type type_tag ::
          :integer
          | :float
          | :binary
          | :bitstring
          | :boolean
          | nil
          | :atom
          | :module
          | :map
          | {:struct, module()}
          | :list
          | :tuple
          | :pid
          | :port
          | :reference
          | :function

  @type t ::
          [{atom(), type_tag() | :present}]
          | {:too_many_keys, non_neg_integer()}
          | :not_a_map

  @doc """
  Shape of a map. Maps with more than `max_keys` keys are recorded as
  `{:too_many_keys, size}` to bound work and storage.

      iex> TeleScope.Runtime.Shape.of(%{duration: 1, source: "users", repo: Enum})
      [duration: :integer, repo: :module, source: :binary]
  """
  @spec of(map(), pos_integer()) :: t()
  def of(map, max_keys \\ 64)

  def of(map, max_keys) when is_map(map) do
    size = map_size(map)

    if size > max_keys do
      {:too_many_keys, size}
    else
      fold(:maps.iterator(map), [], 0)
    end
  end

  def of(_other, _max_keys), do: :not_a_map

  @doc """
  Hot-path variant of `of/2`: same content, no sorting.

  Iteration order is deterministic for a given key set (flatmaps of up to
  32 keys keep keys ordered; larger hash maps order by key hash), so equal
  shapes hash equally. ~4x cheaper than `of/2` on 30-key maps (BENCHMARKS.md).
  """
  @spec of_unsorted(map(), pos_integer()) :: t()
  def of_unsorted(map, max_keys) when is_map(map) do
    size = map_size(map)

    if size > max_keys do
      {:too_many_keys, size}
    else
      case :maps.fold(&fold_entry/3, {[], 0}, map) do
        {acc, 0} -> acc
        {acc, _} -> [{:__non_atom_keys__, :present} | acc]
      end
    end
  end

  def of_unsorted(_other, _max_keys), do: :not_a_map

  defp fold_entry(k, v, {acc, n}) when is_atom(k), do: {[{k, type(v)} | acc], n}
  defp fold_entry(_k, _v, {acc, n}), do: {acc, n + 1}

  defp fold(iter, acc, non_atom) do
    case :maps.next(iter) do
      {k, v, next} when is_atom(k) -> fold(next, [{k, type(v)} | acc], non_atom)
      {_k, _v, next} -> fold(next, acc, non_atom + 1)
      :none -> finish(acc, non_atom)
    end
  end

  defp finish(acc, 0), do: :lists.sort(acc)
  # the count of non-atom keys is not kept: it would create one shape per count
  defp finish(acc, _n), do: :lists.sort([{:__non_atom_keys__, :present} | acc])

  @doc "Type tag of a single value."
  @spec type(term()) :: type_tag()
  def type(v) when is_integer(v), do: :integer
  def type(v) when is_float(v), do: :float
  def type(v) when is_binary(v), do: :binary
  def type(v) when is_bitstring(v), do: :bitstring
  def type(v) when is_boolean(v), do: :boolean
  def type(nil), do: nil

  def type(v) when is_atom(v) do
    # module_loaded/1 is a cheap BIF; unloaded modules are reported as :atom.
    if :erlang.module_loaded(v), do: :module, else: :atom
  end

  def type(%{__struct__: mod}) when is_atom(mod), do: {:struct, mod}
  def type(v) when is_map(v), do: :map
  def type(v) when is_list(v), do: :list
  def type(v) when is_tuple(v), do: :tuple
  def type(v) when is_pid(v), do: :pid
  def type(v) when is_port(v), do: :port
  def type(v) when is_reference(v), do: :reference
  def type(v) when is_function(v), do: :function

  @doc "Human readable type."
  def format_type({:struct, mod}), do: "%#{inspect(mod)}{}"
  def format_type(nil), do: "nil"
  def format_type(t) when is_atom(t), do: Atom.to_string(t)
  def format_type(t), do: inspect(t)
end

defmodule TeleScope.Runtime.ShapeTest do
  use ExUnit.Case, async: true
  alias TeleScope.Runtime.Shape
  doctest TeleScope.Runtime.Shape

  defmodule Inner, do: defstruct([:secret])
  defmodule Outer, do: defstruct([:inner, :name])

  test "types of common values" do
    shape =
      Shape.of(%{
        i: 1,
        f: 1.5,
        b: "x",
        bits: <<1::3>>,
        bool: true,
        n: nil,
        a: :some_unloaded_atom_xyz,
        mod: Enum,
        m: %{a: 1},
        l: [1],
        t: {1},
        p: self(),
        r: make_ref(),
        fun: fn -> :ok end
      })

    assert shape == [
             a: :atom,
             b: :binary,
             bits: :bitstring,
             bool: :boolean,
             f: :float,
             fun: :function,
             i: :integer,
             l: :list,
             m: :map,
             mod: :module,
             n: nil,
             p: :pid,
             r: :reference,
             t: :tuple
           ]
  end

  test "structs keep identity, never contents (nested structs)" do
    value = %Outer{inner: %Inner{secret: "hunter2"}, name: "n"}
    shape = Shape.of(%{conn: value})
    assert shape == [conn: {:struct, Outer}]
    refute inspect(shape) =~ "hunter2"
    refute inspect(shape) =~ "Inner"
  end

  test "empty maps" do
    assert Shape.of(%{}) == []
  end

  test "non-atom keys are collapsed and not retained" do
    shape = Shape.of(%{"user@example.com" => 1, "other" => 2, ok: 1})
    assert shape == [__non_atom_keys__: :present, ok: :integer]
    refute inspect(shape) =~ "example.com"
  end

  test "maps with too many keys are bounded" do
    big = Map.new(1..100, &{:"k#{&1}", &1})
    assert Shape.of(big, 64) == {:too_many_keys, 100}
  end

  test "non-maps" do
    assert Shape.of(:nope) == :not_a_map
  end

  test "shape is deterministic regardless of insertion order" do
    a = Shape.of(Map.new(Enum.map(1..40, &{:"k#{&1}", &1})))
    b = Shape.of(Map.new(Enum.map(40..1//-1, &{:"k#{&1}", &1})))
    assert a == b
  end
end

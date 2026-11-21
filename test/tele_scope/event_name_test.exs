defmodule TeleScope.EventNameTest do
  use ExUnit.Case, async: true
  alias TeleScope.EventName
  doctest TeleScope.EventName

  test "classification" do
    assert EventName.classify([:a, :b]) == :literal
    assert EventName.classify([:a, {:var, :unknown}]) == :partial
    assert EventName.classify([{:splice, :unknown}, :query]) == :partial
    assert EventName.classify([{:splice, :unknown}]) == :dynamic
    assert EventName.classify(:invalid) == :invalid
    assert EventName.classify([]) == :invalid
  end

  test "matching with splices and vars" do
    assert EventName.matches?([:a, {:splice, :unknown}], [:a])
    assert EventName.matches?([:a, {:splice, :unknown}], [:a, :b, :c])
    assert EventName.matches?([{:splice, :unknown}, :q], [:x, :y, :q])
    refute EventName.matches?([{:splice, :unknown}, :q], [:x, :y])
    assert EventName.matches?([:a, {:var, :unknown}, :c], [:a, :b, :c])
    refute EventName.matches?([:a, {:var, :unknown}, :c], [:a, :c])
    refute EventName.matches?(:invalid, [:a])
  end

  test "valid names" do
    assert EventName.valid_name?([:a])
    refute EventName.valid_name?([])
    refute EventName.valid_name?(["a"])
    refute EventName.valid_name?(:a)
    refute EventName.valid_name?([:a | :b])
  end

  test "span split" do
    assert EventName.span_split([:a, :b, :stop]) == {:ok, [:a, :b], :stop}
    assert EventName.span_split([:a, :b]) == :error
  end

  test "parametric helpers" do
    p = [:a, {:var, {:param, 0}}, {:splice, {:param, 1}}]
    assert EventName.parametric?(p)
    refute p |> EventName.forget_params() |> EventName.parametric?()
    assert EventName.format(p) == "[:a, $arg0, $arg1...]"
  end
end

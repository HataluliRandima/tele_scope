defmodule TeleScope.Reporters.JSONTest do
  use ExUnit.Case, async: true
  alias TeleScope.Reporters.JSON

  defp enc(term), do: term |> JSON.encode() |> IO.iodata_to_binary()

  test "scalars, escaping and structures" do
    assert enc(nil) == "null"
    assert enc(%{a: [1, 2.5, true]}) == ~s({"a":[1,2.5,true]})
    assert enc("q\"\\\n\u0001") == ~s("q\\"\\\\\\n\\u0001")
    assert enc(Enum) == ~s("Enum")
    assert enc({Enum, :map, 2}) == ~s("Enum.map/2")
    assert enc(self()) =~ ~r/^"#PID/
    assert enc([:a | :b]) =~ "|"
    assert enc(MapSet.new([1])) == "[1]"
  end

  if Code.ensure_loaded?(:json) and function_exported?(:json, :decode, 1) do
    test "round-trips through OTP's :json decoder" do
      term = %{name: [:a, :b], n: 1, s: "é", nested: %{list: [nil, false]}}

      assert :json.decode(enc(term)) == %{
               "name" => ["a", "b"],
               "n" => 1,
               "s" => "é",
               "nested" => %{"list" => [:null, false]}
             }
    end
  end
end

defmodule TeleScope.Test.FixturesTest do
  # Async on purpose: the helper must be safe while other async modules
  # compile fixtures too.
  use ExUnit.Case, async: true

  alias TeleScope.Test.Fixtures

  test "compile_elixir/3 honours :debug_info under concurrent use" do
    results =
      1..40
      |> Task.async_stream(
        fn i ->
          debug = rem(i, 2) == 0
          dir = Fixtures.tmp_dir("fixtures_race")

          [mod] =
            Fixtures.compile_elixir(
              "defmodule TsFixturesRace#{i} do\n def f, do: #{i}\nend",
              dir,
              debug_info: debug
            )

          {:ok, {_, [debug_info: {:debug_info_v1, _, data}]}} =
            :beam_lib.chunks(String.to_charlist(Path.join(dir, "#{mod}.beam")), [:debug_info])

          {debug, data != :none}
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, fn {wanted, got} -> wanted == got end)
  end
end

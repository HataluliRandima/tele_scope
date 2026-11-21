defmodule TeleScope.MultiNodeTest do
  @moduledoc """
  Runtime capture is node-local (telemetry handlers and trace patterns are
  per VM). This test runs a capture on a peer node via `:peer` (stdio
  connection, no epmd/distribution needed) and merges its result.
  Run with: mix test --include peer
  """
  use ExUnit.Case, async: false
  @moduletag :peer

  test "capture on a peer node and merge into a local catalog" do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
    {:ok, peer, _node} = :peer.start_link(%{connection: :standard_io, args: paths})

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:telemetry])

    result =
      :peer.call(
        peer,
        :erl_eval,
        :expr,
        [
          Code.string_to_quoted!("""
          {:ok, pid} = TeleScope.Runtime.Capture.start(duration: 2_000, events: [[:remote, :known]])
          :telemetry.execute([:remote, :known], %{n: 1}, %{})
          :telemetry.execute([:remote, :dynamic, :x], %{}, %{})
          Process.sleep(100)
          TeleScope.Runtime.Capture.stop(pid)
          """)
          |> :elixir.quoted_to_erl(:elixir.env_for_eval([]))
          |> elem(0),
          []
        ],
        10_000
      )
      |> elem(1)

    :peer.stop(peer)

    cat = TeleScope.Catalog.add_capture(TeleScope.Catalog.new(), result)
    assert TeleScope.Catalog.get(cat, [:remote, :known]).count == 1
    assert TeleScope.Catalog.get(cat, [:remote, :dynamic, :x]).observed
    # nothing leaked into the local node
    refute Enum.any?(:telemetry.list_handlers([:remote]), & &1)
  end
end

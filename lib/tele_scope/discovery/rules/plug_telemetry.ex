defmodule TeleScope.Discovery.Rules.PlugTelemetry do
  @moduledoc """
  Resolves `plug Plug.Telemetry, event_prefix: prefix` (used by every Phoenix
  endpoint) to `prefix ++ [:start]` and `prefix ++ [:stop]`.

  `Plug.Builder` compiles the plug in one of two shapes depending on
  `:plug_init_mode`:

    * `:compile` (prod default) - `Plug.Telemetry.call(conn, {start, stop, opts})`
      with the `init/1` result embedded as a literal
    * `:runtime` (Phoenix dev/test default) -
      `Plug.Telemetry.call(conn, Plug.Telemetry.init([event_prefix: prefix]))`

  Both shapes are handled here, statically, from the caller's BEAM.
  """
  @behaviour TeleScope.Discovery.Rule

  @impl true
  def watched_calls do
    [{Plug.Telemetry, :init, 1}, {Plug.Telemetry, :call, 2}]
  end

  @impl true
  def on_call({Plug.Telemetry, :init, 1}, [opts], ctx) do
    case keyword_value(opts, :event_prefix) do
      {:ok, expr} ->
        prefixes = ctx.eval_name.(expr)
        [{:execute, expand(prefixes), %{plug: Plug.Telemetry, init_mode: :runtime}}]

      :error ->
        []
    end
  end

  def on_call({Plug.Telemetry, :call, 2}, [_conn, state], ctx) do
    case ctx.literal.(state) do
      {:ok, {start, stop, _opts}} when is_list(start) and is_list(stop) ->
        [{:execute, [start, stop], %{plug: Plug.Telemetry, init_mode: :compile}}]

      _ ->
        []
    end
  end

  def on_call(_mfa, _args, _ctx), do: []

  defp expand(prefixes) do
    for p <- prefixes, is_list(p), suffix <- [:start, :stop], do: p ++ [suffix]
  end

  # Finds `key: expr` in an abstract keyword list without requiring the whole
  # list to be literal.
  defp keyword_value({:cons, _, {:tuple, _, [{:atom, _, key}, value]}, _tail}, key),
    do: {:ok, value}

  defp keyword_value({:cons, _, _head, tail}, key), do: keyword_value(tail, key)
  defp keyword_value(_, _), do: :error
end

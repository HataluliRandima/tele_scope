defmodule TeleScope.Test.Synthetic do
  @moduledoc """
  Builds capture results with the same shape as `TeleScope.Runtime.Capture`
  produces, so catalog merging and diagnostics can be tested precisely
  (exact timestamps, counts and handler states) without timing-dependent
  runtime work.
  """

  @t0 1_700_000_000_000

  def t0, do: @t0

  @doc """
  Options:
    * `:events` - `%{name => [measurements: %{key => type}, metadata: ..., count: n, last_seen_at: ms]}`
    * `:attached` - names the observer was attached to (default: keys of `:events`)
    * `:handlers` - `[%{id, event_name, mfa, invocations, tracked_at}]`
    * `:trace_names` - names discovered by the tracer
    * `:trace` - override the trace map (or `nil` with `:trace_error`)
    * `:observer` - extra observer fields (e.g. `status: :crashed`)
    * `:handler_failures` - `[%{handler_id, event, count, kind}]`
  """
  def capture(opts \\ []) do
    events = Keyword.get(opts, :events, %{})
    handlers = Keyword.get(opts, :handlers, [])

    observations =
      Map.merge(
        %{
          status: :stopped,
          error: nil,
          started_at: @t0,
          finished_at: @t0 + 5_000,
          sample_rate: 1.0,
          attached_events: Keyword.get(opts, :attached, Map.keys(events)),
          total_events:
            events |> Map.values() |> Enum.map(&Keyword.get(&1, :count, 1)) |> Enum.sum(),
          recorded_events: 0,
          dropped_events: 0,
          callback_errors: 0,
          ets_rows: 0,
          ets_memory_bytes: 0,
          events: Map.new(events, fn {name, e} -> {name, observation(e)} end),
          handler_failures: Keyword.get(opts, :handler_failures, [])
        },
        Map.new(Keyword.get(opts, :observer, []))
      )

    trace =
      Keyword.get_lazy(opts, :trace, fn ->
        %{
          status: :completed,
          backend: :session,
          messages: 0,
          peak_mailbox: 0,
          gate_closures: 0,
          gated_ms: 0,
          names:
            for(
              n <- Keyword.get(opts, :trace_names, []),
              do: %{name: n, first_seen_at: @t0 + 10, process: nil, via: :execute, count: 1}
            )
        }
      end)

    handlers_after =
      for h <- handlers do
        %{
          id: h.id,
          event_name: h.event_name,
          function: %{type: :external, module: elem(h.mfa, 0), name: elem(h.mfa, 1), mfa: h.mfa},
          config_type: :atom
        }
      end

    %{
      started_at: @t0,
      finished_at: @t0 + 5_000,
      duration_ms: 5_000,
      observations: observations,
      trace: trace,
      trace_error: Keyword.get(opts, :trace_error),
      handlers_before: [],
      handlers_after: handlers_after,
      invocations: Map.new(handlers, &{&1.mfa, Map.get(&1, :invocations, 0)}),
      invocation_tracking_started_at: Map.new(handlers, &{&1.mfa, Map.get(&1, :tracked_at, @t0)}),
      shared_handler_functions: %{}
    }
  end

  defp observation(e) do
    count = Keyword.get(e, :count, 1)

    %{
      count: count,
      count_estimated: false,
      first_seen_at: @t0 + 100,
      last_seen_at: Keyword.get(e, :last_seen_at, @t0 + 200),
      measurements: stats(Keyword.get(e, :measurements, %{}), count),
      metadata: stats(Keyword.get(e, :metadata, %{}), count),
      shape_count: 1,
      shape_overflow: 0,
      processes: []
    }
  end

  defp stats(keys, count),
    do:
      Map.new(keys, fn {k, type} ->
        {k, %{seen: count, types: %{type => count}, presence: 1.0}}
      end)
end

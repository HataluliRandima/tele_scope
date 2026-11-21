defmodule TeleScope.Event do
  @moduledoc """
  One concrete telemetry event name and all evidence collected about it.

  ## Evidence (`sources`)

  Emitter evidence - something can or did emit the event:
    * `:static_literal` - literal name at a telemetry call site
    * `:static_resolved` - resolved through constant propagation, wrapper
      substitution or a call-site rule
    * `:config_rule` - derived from configuration by a rule (e.g. Ecto repo prefix)
    * `:declared` - `telemetry_event` declaration (telemetry_registry convention)
    * `:runtime_trace` - the tracer saw it being emitted
    * `:runtime_observed` - the observer handler received it

  Consumer evidence - something expects the event:
    * `:handler_registration` - static `attach/attach_many` call site
    * `:runtime_handler` - a handler is attached at runtime
    * `:metric_definition` - a `Telemetry.Metrics` definition references it

  ## Status (see `status/2`)

    * `:observed` - fired during a runtime capture
    * `:not_observed` - a capture ran while the observer was attached to
      this name, and it did not fire *in that window*. This never means the
      event does not exist.
    * `:static_only` - no runtime capture covered this name
    * `:referenced_only` - only consumers (handlers/metrics) mention it; no
      emitter was found (possible typo, dynamic emitter, or unscanned code)
  """

  @emitter_sources [
    :static_literal,
    :static_resolved,
    :config_rule,
    :declared,
    :runtime_trace,
    :runtime_observed
  ]

  @type t :: %__MODULE__{}

  defstruct name: nil,
            span: nil,
            apps: MapSet.new(),
            sources: MapSet.new(),
            call_sites: [],
            rule_reasons: [],
            declaration: nil,
            observed: nil,
            count: 0,
            count_estimated: false,
            first_seen_at: nil,
            last_seen_at: nil,
            measurements: %{},
            metadata: %{},
            shape_count: 0,
            processes: [],
            trace: nil,
            handlers: [],
            static_handlers: [],
            metrics: []

  def new(name) do
    span =
      case TeleScope.EventName.span_split(name) do
        {:ok, prefix, role} -> %{prefix: prefix, role: role}
        :error -> nil
      end

    %__MODULE__{name: name, span: span}
  end

  def emitter_sources, do: @emitter_sources

  @doc "Does any evidence say this event is emitted?"
  def emitter_known?(%__MODULE__{sources: s}),
    do: Enum.any?(@emitter_sources, &MapSet.member?(s, &1))

  @doc """
  Discovery confidence, strongest first:
  `:observed` > `:literal` > `:resolved` > `:configured` > `:declared` > `:referenced`.
  """
  def confidence(%__MODULE__{sources: s}) do
    cond do
      MapSet.member?(s, :runtime_observed) or MapSet.member?(s, :runtime_trace) -> :observed
      MapSet.member?(s, :static_literal) -> :literal
      MapSet.member?(s, :static_resolved) -> :resolved
      MapSet.member?(s, :config_rule) -> :configured
      MapSet.member?(s, :declared) -> :declared
      true -> :referenced
    end
  end

  @doc "Status given whether a runtime capture covered this event."
  def status(%__MODULE__{} = e) do
    cond do
      e.observed == true -> :observed
      e.observed == false -> :not_observed
      not emitter_known?(e) -> :referenced_only
      true -> :static_only
    end
  end
end

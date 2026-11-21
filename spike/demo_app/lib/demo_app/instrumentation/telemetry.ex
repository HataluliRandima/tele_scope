defmodule DemoApp.Instrumentation.Telemetry do
  @moduledoc """
  Spike fixture: a typical application-level telemetry *wrapper*.
  Event names are built from a parameter, so static discovery must resolve
  them at the call sites (wrapper resolution).
  """

  @app :demo_app

  # wrapper with a list parameter: [:demo_app | suffix]
  def emit(suffix, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute([@app | suffix], measurements, metadata)
  end

  # wrapper with an atom parameter, span-based: [:demo_app, name, :start|:stop|:exception]
  def span(name, metadata, fun) do
    :telemetry.span([@app, name], metadata, fun)
  end
end

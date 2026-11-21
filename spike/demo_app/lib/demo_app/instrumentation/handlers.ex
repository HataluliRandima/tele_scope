defmodule DemoApp.Instrumentation.Handlers do
  @moduledoc "Spike fixture: custom handlers, including deliberate mistakes."
  require Logger

  @events [
    [:demo_app, :orders, :created],
    [:demo_app, :checkout, :stop],
    [:demo_app, :payment, :captured]
  ]

  def attach do
    :telemetry.attach_many("demo-app-orders", @events, &__MODULE__.handle_event/4, %{api_key: "s3cr3t"})

    # anonymous function handler
    :telemetry.attach("demo-app-cancel-log", [:demo_app, :orders, :cancelled], fn _e, _m, md, _c ->
      _ = md.reason
      :ok
    end, nil)

    # deliberate typo: :order instead of :orders -> never fires
    :telemetry.attach("demo-app-typo", [:demo_app, :order, :created], &__MODULE__.handle_event/4, nil)

    # attached to a real event that the workload never triggers
    :telemetry.attach("demo-app-refund", [:demo_app, :payment, :refunded], &__MODULE__.handle_refund/4, nil)

    # crashing handler -> detached by :telemetry on first event
    :telemetry.attach("demo-app-crasher", [:demo_app, :cache, :miss], &__MODULE__.crash/4, nil)
    :ok
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok
  def handle_refund(_event, _measurements, _metadata, _config), do: :ok
  def crash(_event, _measurements, _metadata, _config), do: raise("handler bug")
end

defmodule DemoApp.Instrumentation.Customer do
  defstruct [:id, :email, :address]
end

defmodule DemoApp.Instrumentation.Address do
  defstruct [:city]
end

defmodule DemoApp.Instrumentation.Orders do
  @moduledoc "Spike fixture covering literal / partial / dynamic / wrapped / span instrumentation."
  alias DemoApp.Instrumentation.{Address, Customer, Telemetry}

  @created_event [:demo_app, :orders, :created]

  # 1. literal (module attribute is inlined at compile time)
  def create(id) do
    customer = %Customer{id: id, email: "user#{id}@example.com", address: %Address{city: "Lisbon"}}

    :telemetry.execute(@created_event, %{count: 1, total_cents: 1999}, %{
      order_id: id,
      currency: "EUR",
      customer: customer,
      coupon: if(rem(id, 2) == 0, do: "SAVE10", else: nil),
      password_hint: "never-store-me"
    })
  end

  # 1b. literal via local variable binding (constant propagation)
  def cancel(id) do
    event = [:demo_app, :orders, :cancelled]
    reason = if rem(id, 3) == 0, do: :fraud, else: :customer_request
    :telemetry.execute(event, %{}, %{order_id: id, reason: reason})
  end

  # 1c. literal alternatives through if/case
  def settle(id, ok?) do
    outcome = if ok?, do: :succeeded, else: :failed
    :telemetry.execute([:demo_app, :payment, outcome], %{amount: id * 10}, %{})
  end

  # 2. partial: one unknown segment from runtime data
  def cache(op) when op in [:hit, :miss, :evict] do
    :telemetry.execute([:demo_app, :cache, op], %{}, %{key_type: :order})
  end

  def cache_from_string(op_string) do
    :telemetry.execute([:demo_app, :cache, String.to_existing_atom(op_string)], %{}, %{})
  end

  # 2b. partial: configurable prefix ++ known suffix (Ecto style)
  def search(term) do
    prefix = Application.get_env(:demo_app, :search_telemetry_prefix, [:demo_app, :search])
    :telemetry.execute(prefix ++ [:query], %{results: String.length(term)}, %{})
  end

  # 3. dynamic: name built from a string at runtime
  def dynamic(kind) do
    name = "demo_app.dynamic.#{kind}" |> String.split(".") |> Enum.map(&String.to_atom/1)
    :telemetry.execute(name, %{value: 1}, %{kind: kind})
  end

  # 4. wrapped calls
  def capture_payment(id) do
    Telemetry.emit([:payment, :captured], %{amount: 100}, %{order_id: id})
  end

  def refund(id), do: Telemetry.emit([:payment, :refunded], %{amount: 50}, %{order_id: id})

  # 5. span (direct and through the wrapper)
  def checkout(id) do
    :telemetry.span([:demo_app, :checkout], %{order_id: id}, fn ->
      Process.sleep(1)
      {:ok, %{order_id: id, items: 3}}
    end)
  end

  def fulfil(id) do
    Telemetry.span(:fulfilment, %{order_id: id}, fn ->
      if rem(id, 5) == 0, do: raise("warehouse down")
      {:ok, %{order_id: id}}
    end)
  end

  # lazy execution (telemetry >= 1.4): only computed when handlers exist
  def lazy(id) do
    if function_exported?(:telemetry, :execute_lazy, 3) do
      :telemetry.execute_lazy([:demo_app, :orders, :audited], :ok, fn ->
        {:ok, {%{count: 1}, %{order_id: id}}}
      end)
    end
  end
end

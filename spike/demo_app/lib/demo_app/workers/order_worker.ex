defmodule DemoApp.Workers.OrderWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  alias DemoApp.Instrumentation.Orders

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    Orders.create(id)
    Orders.checkout(id)
    DemoApp.Repo.query!("SELECT count(*) FROM products")
    :ok
  end
end

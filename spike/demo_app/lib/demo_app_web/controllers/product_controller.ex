defmodule DemoAppWeb.ProductController do
  use DemoAppWeb, :controller

  def index(conn, _params) do
    %{rows: rows} = DemoApp.Repo.query!("SELECT id, name FROM products ORDER BY id LIMIT 10")
    DemoApp.Instrumentation.Orders.search("prod")
    json(conn, %{products: Enum.map(rows, fn [id, name] -> %{id: id, name: name} end)})
  end

  def boom(_conn, _params), do: raise("boom")
end

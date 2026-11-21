defmodule DemoApp.Repo.Migrations.CreateSpikeTables do
  use Ecto.Migration

  def up do
    create table(:products) do
      add :name, :string
    end

    Oban.Migration.up()
  end

  def down do
    Oban.Migration.down()
    drop table(:products)
  end
end

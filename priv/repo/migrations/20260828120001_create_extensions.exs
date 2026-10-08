defmodule Factory.Repo.Migrations.CreateExtensions do
  use Ecto.Migration

  # `citext` makes task codes case-insensitive in the database: "t-001" and "T-001" are the
  # same task.
  def up do
    execute("CREATE EXTENSION IF NOT EXISTS citext")
  end

  def down do
    execute("DROP EXTENSION IF EXISTS citext")
  end
end

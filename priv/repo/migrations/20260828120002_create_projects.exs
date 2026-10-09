defmodule Factory.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :name, :string, null: false
      add :path, :string, null: false
      add :domain, :string, null: false, default: "software"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:name])

    create table(:specialists) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :identifier, :string, null: false
      add :name, :string, null: false
      add :prompt, :text, null: false
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create index(:specialists, [:project_id])

    # Unique among active rows only: changing a prompt inserts a new row and deactivates the
    # previous one, which keeps the specialist's history.
    create unique_index(:specialists, [:project_id, :identifier],
             where: "active",
             name: :specialists_active_per_project
           )
  end
end

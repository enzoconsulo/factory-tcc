defmodule Factory.Repo.Migrations.CreatePhases do
  use Ecto.Migration

  # Plan phases and the milestones that close each one, imported from `_management/PLAN.md`.
  def change do
    create table(:phases) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :version, :string, null: false
      add :title, :string
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:phases, [:project_id, :version])
    create index(:phases, [:project_id, :position])
    create constraint(:phases, :position_positive, check: "position >= 1")

    create table(:milestones) do
      add :phase_id, references(:phases, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :task_code, :citext
      add :position, :integer, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:milestones, [:phase_id, :position])
    create constraint(:milestones, :position_positive, check: "position >= 1")
  end
end

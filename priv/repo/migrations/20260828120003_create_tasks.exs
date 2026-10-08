defmodule Factory.Repo.Migrations.CreateTasks do
  use Ecto.Migration

  def change do
    create table(:tasks) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :code, :citext, null: false
      add :title, :string, null: false
      add :goal, :text
      add :context, :text
      add :status, :string, null: false, default: "backlog"
      add :priority, :string, null: false, default: "medium"
      add :attempts, :integer, null: false, default: 0
      add :specialist_id, references(:specialists, on_delete: :nilify_all)
      add :replanned_from_id, references(:tasks, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:tasks, [:project_id, :code])
    create index(:tasks, [:project_id, :status])
    create index(:tasks, [:specialist_id])
    create index(:tasks, [:replanned_from_id])

    # `attempts` is written by the system only; the database at least rejects negatives.
    create constraint(:tasks, :attempts_non_negative, check: "attempts >= 0")

    # One row per dependency pair, so unblocking is a query rather than a scan.
    create table(:task_dependencies) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :depends_on_id, references(:tasks, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_dependencies, [:task_id, :depends_on_id])
    create index(:task_dependencies, [:depends_on_id])

    # A self-dependency is a cycle of length 1; longer cycles are detected by the scheduler.
    create constraint(:task_dependencies, :dependency_not_reflexive,
             check: "task_id <> depends_on_id"
           )

    # One file per row, never a directory: `areas` is the parallelism mutex.
    create table(:task_areas) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :path, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:task_areas, [:task_id, :path])
    create index(:task_areas, [:path])

    create table(:criteria) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :text, :text, null: false
      add :command, :string
      add :level, :string, null: false, default: "inspected"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:criteria, [:task_id])
  end
end

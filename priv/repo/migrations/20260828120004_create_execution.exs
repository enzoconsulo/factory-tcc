defmodule Factory.Repo.Migrations.CreateExecution do
  use Ecto.Migration

  def change do
    # A new row per rework, never overwritten, so each cycle's cost can be queried.
    create table(:cycles) do
      add :task_id, references(:tasks, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :role, :string, null: false
      add :outcome, :string
      add :report, :text

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cycles, [:task_id, :number, :role])
    create index(:cycles, [:task_id])
    create constraint(:cycles, :number_positive, check: "number >= 1")

    create table(:dispatches) do
      add :cycle_id, references(:cycles, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      add :model, :string, null: false
      add :turns, :integer, null: false, default: 0
      add :started_at, :utc_datetime_usec
      add :finished_at, :utc_datetime_usec
      add :outcome, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:dispatches, [:cycle_id])
    create constraint(:dispatches, :turns_non_negative, check: "turns >= 0")

    # One row per turn, keeping the input / cache read / cache write split.
    create table(:usages) do
      add :dispatch_id, references(:dispatches, on_delete: :delete_all), null: false
      add :turn, :integer, null: false
      add :input_tokens, :integer, null: false, default: 0
      add :cache_write_tokens, :integer, null: false, default: 0
      add :cache_read_tokens, :integer, null: false, default: 0
      add :output_tokens, :integer, null: false, default: 0
      add :cost_usd, :decimal, precision: 12, scale: 6, null: false, default: 0
      add :quota_units, :decimal, precision: 12, scale: 6, null: false, default: 0
      add :duration_ms, :integer

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:usages, [:dispatch_id, :turn])
    create constraint(:usages, :turn_positive, check: "turn >= 1")

    create constraint(:usages, :tokens_non_negative,
             check: """
             input_tokens >= 0 AND cache_write_tokens >= 0
             AND cache_read_tokens >= 0 AND output_tokens >= 0
             """
           )
  end
end

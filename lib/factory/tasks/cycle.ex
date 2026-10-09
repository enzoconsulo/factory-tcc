defmodule Factory.Tasks.Cycle do
  @moduledoc """
  One pass of a task through a pipeline role. Every rework adds a new row; rows are never
  overwritten, so the cost of each cycle can be queried separately.

  `role` and `outcome` are plain strings rather than enums, so the vocabulary of both tracks
  can evolve without a migration.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Tasks.Dispatch
  alias Factory.Tasks.Task

  @type t :: %__MODULE__{}

  schema "cycles" do
    field :number, :integer
    field :role, :string
    field :outcome, :string
    field :report, :string

    belongs_to :task, Task
    has_many :dispatches, Dispatch

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(cycle, attrs) do
    cycle
    |> cast(attrs, [:task_id, :number, :role, :outcome, :report])
    |> validate_required([:task_id, :number, :role])
    |> validate_number(:number, greater_than_or_equal_to: 1)
    |> assoc_constraint(:task)
    |> unique_constraint([:task_id, :number, :role])
    |> check_constraint(:number, name: :number_positive)
  end
end

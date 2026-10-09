defmodule Factory.Tasks.Dependency do
  @moduledoc """
  An edge of the dependency graph: `task_id` depends on `depends_on_id`. A join table, so
  "which tasks unblock when this one is done?" is a query rather than a scan.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Tasks.Task

  @type t :: %__MODULE__{}

  schema "task_dependencies" do
    belongs_to :task, Task
    belongs_to :depends_on, Task

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(dependency, attrs) do
    dependency
    |> cast(attrs, [:task_id, :depends_on_id])
    |> validate_required([:task_id, :depends_on_id])
    |> assoc_constraint(:task)
    |> assoc_constraint(:depends_on)
    |> unique_constraint([:task_id, :depends_on_id])
    |> check_constraint(:depends_on_id,
      name: :dependency_not_reflexive,
      message: "a task cannot depend on itself"
    )
  end
end

defmodule Factory.Tasks.Area do
  @moduledoc """
  A file the task declares it will touch: one per row, never a directory.

  `areas` is the parallelism mutex: two tasks only run together when their sets do not
  intersect. Storing directories would turn the intersection into a prefix comparison,
  which yields false negatives.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Tasks.Task

  @type t :: %__MODULE__{}

  schema "task_areas" do
    field :path, :string

    belongs_to :task, Task

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(area, attrs) do
    area
    |> cast(attrs, [:task_id, :path])
    |> validate_required([:task_id, :path])
    |> assoc_constraint(:task)
    |> unique_constraint([:task_id, :path])
  end
end

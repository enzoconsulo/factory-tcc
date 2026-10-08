defmodule Factory.Projects.Milestone do
  @moduledoc """
  A milestone inside a `Factory.Projects.Phase`, read from `_management/PLAN.md`.

  `task_code` is free text rather than a foreign key: a milestone may cite a task that has not
  been imported yet or that belongs to another project.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Projects.Phase

  @type t :: %__MODULE__{}

  schema "milestones" do
    field :title, :string
    field :task_code, :string
    field :position, :integer

    belongs_to :phase, Phase

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:phase_id, :title, :task_code, :position]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(milestone, attrs) do
    milestone
    |> cast(attrs, @fields)
    |> validate_required([:phase_id, :title, :position])
    |> validate_number(:position, greater_than_or_equal_to: 1)
    |> assoc_constraint(:phase)
    |> unique_constraint([:phase_id, :position])
    |> check_constraint(:position, name: :position_positive)
  end
end

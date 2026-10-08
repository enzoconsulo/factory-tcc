defmodule Factory.Projects.Phase do
  @moduledoc """
  A phase of a project's plan, read from `_management/PLAN.md`. `position` keeps the order
  in which the phase appears in the document, independently of the `version` text.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Projects.Milestone
  alias Factory.Projects.Project

  @type t :: %__MODULE__{}

  schema "phases" do
    field :version, :string
    field :title, :string
    field :position, :integer

    belongs_to :project, Project
    has_many :milestones, Milestone

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:project_id, :version, :title, :position]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(phase, attrs) do
    phase
    |> cast(attrs, @fields)
    |> validate_required([:project_id, :version, :position])
    |> validate_number(:position, greater_than_or_equal_to: 1)
    |> assoc_constraint(:project)
    |> unique_constraint([:project_id, :version])
    |> check_constraint(:position, name: :position_positive)
  end
end

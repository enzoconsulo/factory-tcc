defmodule Factory.Projects.Specialist do
  @moduledoc """
  A member of a project's team of specialists. Specialists are versioned data: changing a
  prompt inserts a new row and marks the previous one `active: false`, so the same specialist
  can be compared before and after a change. A partial unique index (`where: "active"`)
  enforces one active row per identifier and project.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Projects.Project

  @type t :: %__MODULE__{}

  schema "specialists" do
    field :identifier, :string
    field :name, :string
    field :prompt, :string
    field :active, :boolean, default: true

    belongs_to :project, Project

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:project_id, :identifier, :name, :prompt, :active]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(specialist, attrs) do
    specialist
    |> cast(attrs, @fields)
    |> validate_required([:project_id, :identifier, :name, :prompt])
    |> assoc_constraint(:project)
    |> unique_constraint([:project_id, :identifier],
      name: :specialists_active_per_project,
      message: "an active specialist with this identifier already exists in the project"
    )
  end
end

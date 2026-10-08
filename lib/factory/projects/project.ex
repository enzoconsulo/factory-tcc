defmodule Factory.Projects.Project do
  @moduledoc """
  A project built by the factory.

  `domain` routes the whole pipeline: `"software"` uses the software track, any other value
  uses the generic track. A missing domain means software, hence the default.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Projects.Specialist
  alias Factory.Tasks.Task

  @type t :: %__MODULE__{}

  schema "projects" do
    field :name, :string
    field :path, :string
    field :domain, :string, default: "software"

    has_many :specialists, Specialist
    has_many :tasks, Task

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:name, :path, :domain]

  @doc "Project changeset. `domain` is free text on purpose: domains are not a closed list."
  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(project, attrs) do
    project
    |> cast(attrs, @fields)
    |> validate_required([:name, :path])
    |> validate_length(:name, min: 1, max: 100)
    |> unique_constraint(:name)
  end
end

defmodule Factory.Tasks.Task do
  @moduledoc """
  The factory's unit of work.

  `status` is an `Ecto.Enum` with the six pipeline states plus the two terminal ones, so an
  invented status never reaches the database. This module is only the schema; transition
  rules do not live here.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Projects.Project
  alias Factory.Projects.Specialist
  alias Factory.Tasks.Area
  alias Factory.Tasks.Criterion
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Dependency

  @type t :: %__MODULE__{}

  @states [:backlog, :ready, :in_progress, :in_testing, :in_review, :done]
  @terminal_states [:blocked, :cancelled]

  @doc "The six pipeline states, in the order a task goes through them."
  @spec states() :: [atom()]
  def states, do: @states

  @doc "The terminal states, which lead nowhere."
  @spec terminal_states() :: [atom()]
  def terminal_states, do: @terminal_states

  schema "tasks" do
    field :code, :string
    field :title, :string
    field :goal, :string
    field :context, :string
    field :status, Ecto.Enum, values: @states ++ @terminal_states, default: :backlog
    field :priority, Ecto.Enum, values: [:high, :medium, :low], default: :medium
    field :attempts, :integer, default: 0

    belongs_to :project, Project
    belongs_to :specialist, Specialist
    belongs_to :replanned_from, __MODULE__

    has_many :areas, Area
    has_many :criteria, Criterion
    has_many :cycles, Cycle
    has_many :dependencies, Dependency

    timestamps(type: :utc_datetime_usec)
  end

  @fields [
    :project_id,
    :code,
    :title,
    :goal,
    :context,
    :status,
    :priority,
    :attempts,
    :specialist_id,
    :replanned_from_id
  ]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(task, attrs) do
    task
    |> cast(attrs, @fields)
    |> validate_required([:project_id, :code, :title])
    |> validate_format(:code, ~r/^T-\d{3,}[a-z]*$/i,
      message: "must be T-NNN, with an optional letter suffix for replanning"
    )
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> assoc_constraint(:project)
    |> assoc_constraint(:specialist)
    |> unique_constraint([:project_id, :code])
    |> check_constraint(:attempts, name: :attempts_non_negative)
  end
end

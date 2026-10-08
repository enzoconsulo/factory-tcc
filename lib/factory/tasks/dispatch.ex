defmodule Factory.Tasks.Dispatch do
  @moduledoc """
  One call to a provider within a cycle: which adapter, which model, how many turns.
  Token usage lives in `Factory.Tasks.Usage`, one row per turn.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Usage

  @type t :: %__MODULE__{}

  schema "dispatches" do
    field :provider, :string
    field :model, :string
    field :turns, :integer, default: 0
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    field :outcome, :string

    belongs_to :cycle, Cycle
    has_many :usages, Usage

    timestamps(type: :utc_datetime_usec)
  end

  @fields [:cycle_id, :provider, :model, :turns, :started_at, :finished_at, :outcome]

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(dispatch, attrs) do
    dispatch
    |> cast(attrs, @fields)
    |> validate_required([:cycle_id, :provider, :model])
    |> validate_number(:turns, greater_than_or_equal_to: 0)
    |> assoc_constraint(:cycle)
    |> check_constraint(:turns, name: :turns_non_negative)
  end
end

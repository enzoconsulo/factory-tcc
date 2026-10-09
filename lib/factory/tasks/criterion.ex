defmodule Factory.Tasks.Criterion do
  @moduledoc """
  An acceptance criterion of a task, with the proof level at which it is verified:
  `:executed` (a command runs and its exit code decides), `:inspected` (someone opens the
  artifact and checks) or `:judged` (rubric).

  `command` is nil exactly when the level is not `:executed`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Factory.Tasks.Task

  @type t :: %__MODULE__{}

  @levels [:executed, :inspected, :judged]

  @doc "The proof levels, strongest first."
  @spec levels() :: [atom()]
  def levels, do: @levels

  schema "criteria" do
    field :text, :string
    field :command, :string
    field :level, Ecto.Enum, values: @levels, default: :inspected

    belongs_to :task, Task

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(criterion, attrs) do
    criterion
    |> cast(attrs, [:task_id, :text, :command, :level])
    |> validate_required([:task_id, :text])
    |> assoc_constraint(:task)
    |> validate_command_matches_level()
  end

  defp validate_command_matches_level(changeset) do
    case {get_field(changeset, :level), get_field(changeset, :command)} do
      {:executed, nil} ->
        add_error(changeset, :command, "an executed criterion needs a command")

      {level, command} when level != :executed and is_binary(command) ->
        add_error(changeset, :level, "a criterion with a command must have level :executed")

      _ ->
        changeset
    end
  end
end

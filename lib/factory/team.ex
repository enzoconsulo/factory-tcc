defmodule Factory.Team do
  @moduledoc """
  The project's specialists as VERSIONED data, and the resolution of who executes a task.

  Changing a specialist's prompt inserts a new row and marks the previous one inactive — never
  an `UPDATE` of the text — so "did this specialist get better after I changed its prompt?"
  stays answerable. The rule lives in the database's partial unique index
  (`specialists_active_per_project`, `where: "active"`); this module only follows it.

  `define/2` deactivates and inserts in one transaction: a crash in between would otherwise
  leave the project with no active specialist, silently falling back to the generic role.
  """

  import Ecto.Query, only: [from: 2]

  alias Factory.Projects.Specialist
  alias Factory.Repo
  alias Factory.Tasks.Task
  alias Factory.Team.Resolution

  @doc """
  Defines the current version of a specialist: deactivates the previous one and inserts the
  new one. Calling twice with the same text creates two versions, on purpose.
  """
  @spec define(pos_integer(), map()) :: {:ok, Specialist.t()} | {:error, term()}
  def define(project_id, attrs) do
    identifier = Map.get(attrs, :identifier) || Map.get(attrs, "identifier")

    # A function transaction rather than `Ecto.Multi`: there is nothing to compose, and
    # `Multi.new()` trips a Dialyzer opacity warning on its internal `MapSet`.
    Repo.transaction(fn ->
      {_deactivated, _} = Repo.update_all(deactivate_query(project_id, identifier), [])

      case Repo.insert(new_changeset(project_id, attrs)) do
        {:ok, specialist} -> specialist
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, specialist} -> {:ok, specialist}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deactivate_query(project_id, identifier) do
    from(s in Specialist,
      where: s.project_id == ^project_id and s.identifier == ^identifier and s.active,
      update: [set: [active: false, updated_at: ^DateTime.utc_now()]]
    )
  end

  defp new_changeset(project_id, attrs) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.put("project_id", project_id)
      |> Map.put("active", true)

    Specialist.changeset(%Specialist{}, attrs)
  end

  @doc "The project's ACTIVE specialists, ordered by identifier."
  @spec list_active(pos_integer()) :: [Specialist.t()]
  def list_active(project_id) do
    Repo.all(
      from(s in Specialist,
        where: s.project_id == ^project_id and s.active,
        order_by: s.identifier
      )
    )
  end

  @doc "The active specialist with this identifier, or `nil`."
  @spec active(pos_integer(), String.t()) :: Specialist.t() | nil
  def active(project_id, identifier) do
    Repo.one(
      from(s in Specialist,
        where:
          s.project_id == ^project_id and s.identifier == ^identifier and
            s.active
      )
    )
  end

  @doc "Every version of this specialist, newest first."
  @spec history(pos_integer(), String.t()) :: [Specialist.t()]
  def history(project_id, identifier) do
    Repo.all(
      from(s in Specialist,
        where: s.project_id == ^project_id and s.identifier == ^identifier,
        order_by: [desc: s.id]
      )
    )
  end

  @doc """
  Who executes this task in this role. Follows the task's reference to the **active**
  specialist with the same identifier. A dangling reference falls back to the generic role with
  the defect recorded — never silently, and never by refusing the dispatch.
  """
  @spec resolve(Task.t(), atom()) :: Resolution.t()
  def resolve(%Task{specialist_id: nil} = task, role) do
    Resolution.resolve(role, nil, list_active(task.project_id))
  end

  def resolve(%Task{} = task, role) do
    case Repo.get(Specialist, task.specialist_id) do
      nil -> Resolution.unknown(role, {:id, task.specialist_id})
      referenced -> Resolution.resolve(role, referenced.identifier, list_active(task.project_id))
    end
  end
end

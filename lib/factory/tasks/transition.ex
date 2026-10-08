defmodule Factory.Tasks.Transition do
  @moduledoc """
  Changes a task's status. Status, report and cost are written in the SAME transaction, or
  nothing is written.

  ## What a transition writes

  | write | when | source |
  |---|---|---|
  | `tasks.status` | always | the `to` state |
  | `tasks.attempts` | only when entering `in_progress` | incremented by the system |
  | a row in `cycles` | when `:role` is given | the stage's report |
  | a row in `dispatches` | when `:dispatch` is given | provider and model |
  | N rows in `usages` | when `:usages` is given | one per turn |

  None of these is required together (handing a task to the builder has no report yet), but
  a report or a cost is never written without the status change that explains it.

  `attempts` counts how many times the task has been handed to a builder, so when choosing
  the model of the next dispatch, `attempts >= 1` means there was a previous run.

  The cycle number is `max(attempts_before_the_transition, 1)`, read before the increment:
  the verifier's rejection lands on the cycle that just failed, and the builder, verifier and
  reviewer of one pass share a number, as the unique index `(task, number, role)` expects.

  The task row is read `FOR UPDATE` inside the transaction, so concurrent transitions on the
  same task serialize.
  """

  # `apply/3` is this module's public name; the Kernel function of the same arity is unused.
  import Kernel, except: [apply: 3]
  import Ecto.Query, only: [from: 2]

  alias Ecto.Multi
  alias Factory.Repo
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Dispatch
  alias Factory.Tasks.StateMachine
  alias Factory.Tasks.Task
  alias Factory.Tasks.Usage

  @type error ::
          {:invalid_transition, atom(), atom()}
          | {:task_not_found, term()}
          | {:invalid, atom(), Ecto.Changeset.t()}
          | :dispatch_without_cycle
          | :usage_without_dispatch

  @doc """
  Applies the transition. Returns the task in its new state, or a named error.

  ## Options

    * `:role` — who just worked. When present, writes a row in `cycles`.
    * `:outcome` and `:report` — what that stage concluded, and the report text.
    * `:dispatch` — map with `:provider`, `:model` and `:turns`. Requires `:role`.
    * `:usages` — list of maps, one per turn. Requires `:dispatch`. Without an explicit
      `:turn`, the position in the list becomes the turn number.

  ## Errors

  `{:error, {:invalid_transition, from, to}}` · `{:error, {:task_not_found, id}}` ·
  `{:error, {:invalid, step, changeset}}` · `{:error, :dispatch_without_cycle}` ·
  `{:error, :usage_without_dispatch}`
  """
  @spec apply(Task.t() | integer(), atom(), keyword()) :: {:ok, Task.t()} | {:error, error()}
  def apply(task, to, opts \\ [])

  def apply(%Task{id: id}, to, opts), do: apply(id, to, opts)

  def apply(id, to, opts) do
    with :ok <- check_opts(opts) do
      id
      |> build(to, opts)
      |> Repo.transaction()
      |> translate()
    end
  end

  @doc """
  The transition's `Ecto.Multi`, without running it. Public so tests can inspect a failed
  transaction and so callers can compose it with other writes (e.g. enqueuing a job).
  """
  @spec build(integer(), atom(), keyword()) :: Multi.t()
  def build(id, to, opts \\ []), do: append(Multi.new(), id, to, opts)

  @doc """
  The same steps, appended to an existing `Ecto.Multi`. `build/3` is the case where the
  Multi starts empty.
  """
  @spec append(Multi.t(), integer(), atom(), keyword()) :: Multi.t()
  def append(multi, id, to, opts \\ []) do
    multi
    |> Multi.run(:current, fn repo, _done -> load(repo, id) end)
    |> Multi.run(:checked, fn _repo, done -> check(done, to) end)
    |> Multi.run(:task, fn repo, done -> move(repo, done, to) end)
    |> maybe_cycle(opts)
    |> maybe_dispatch(opts)
    |> usages(opts)
  end

  # Read inside the transaction with a row lock: the status checked and the attempts
  # incremented must be the database's at write time, not those of a stale struct.
  defp load(repo, id) do
    case repo.one(from(t in Task, where: t.id == ^id, lock: "FOR UPDATE")) do
      nil -> {:error, {:task_not_found, id}}
      task -> {:ok, task}
    end
  end

  defp check(%{current: task}, to) do
    case StateMachine.check(task.status, to) do
      :ok -> {:ok, {task.status, to}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp move(repo, %{current: task}, to) do
    task
    |> Task.changeset(move_attrs(task, to))
    |> repo.update()
  end

  defp move_attrs(task, to) do
    if StateMachine.hands_to_builder?(to) do
      %{status: to, attempts: task.attempts + 1}
    else
      %{status: to}
    end
  end

  defp maybe_cycle(multi, opts) do
    case Keyword.get(opts, :role) do
      nil -> multi
      role -> Multi.insert(multi, :cycle, &cycle_changeset(&1, role, opts))
    end
  end

  defp cycle_changeset(%{current: task}, role, opts) do
    Cycle.changeset(%Cycle{}, %{
      task_id: task.id,
      # Before the increment (see the moduledoc).
      number: max(task.attempts, 1),
      role: role,
      outcome: Keyword.get(opts, :outcome),
      report: Keyword.get(opts, :report)
    })
  end

  defp maybe_dispatch(multi, opts) do
    case Keyword.get(opts, :dispatch) do
      nil ->
        multi

      attrs ->
        Multi.insert(multi, :dispatch, fn %{cycle: cycle} ->
          Dispatch.changeset(%Dispatch{}, Map.put(attrs, :cycle_id, cycle.id))
        end)
    end
  end

  defp usages(multi, opts) do
    opts
    |> Keyword.get(:usages, [])
    |> Enum.with_index(1)
    |> Enum.reduce(multi, fn {attrs, position}, acc ->
      Multi.insert(acc, {:usage, position}, fn %{dispatch: dispatch} ->
        Usage.changeset(%Usage{}, with_dispatch(attrs, dispatch, position))
      end)
    end)
  end

  defp with_dispatch(attrs, dispatch, position) do
    attrs
    |> Map.put_new(:turn, position)
    |> Map.put(:dispatch_id, dispatch.id)
  end

  # Option dependencies are checked before opening the transaction; otherwise a missing
  # `:cycle`/`:dispatch` step would surface as a MatchError inside the Multi. The VALUE
  # decides, not the key's presence (`role: nil` means no cycle).
  defp check_opts(opts) do
    has_cycle? = Keyword.get(opts, :role) != nil
    has_dispatch? = Keyword.get(opts, :dispatch) != nil
    has_usage? = opts |> Keyword.get(:usages, []) |> Enum.any?()

    cond do
      has_dispatch? and not has_cycle? -> {:error, :dispatch_without_cycle}
      has_usage? and not has_dispatch? -> {:error, :usage_without_dispatch}
      true -> :ok
    end
  end

  defp translate({:ok, %{task: task}}), do: {:ok, task}

  defp translate({:error, step, %Ecto.Changeset{} = changeset, _done}),
    do: {:error, {:invalid, step_name(step), changeset}}

  defp translate({:error, _step, reason, _done}), do: {:error, reason}

  defp step_name({:usage, position}), do: :"usage_#{position}"
  defp step_name(step), do: step
end

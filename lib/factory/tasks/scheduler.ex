defmodule Factory.Tasks.Scheduler do
  @moduledoc """
  Decides which tasks become `ready` and what to dispatch now. Pure functions: no database
  access. If a rule fits in a test it is code; replanning and milestone verdicts remain
  judgement.

  ## Dependency rules

    * A `done` dependency is satisfied.
    * A `cancelled` dependency is satisfied by its replacements (`replanned_from_id`),
      recursively, and only if there is at least one replacement and every replacement is
      satisfied. A cancelled task without replacements was discarded, so it never satisfies.
    * A `blocked` dependency is not satisfied: blocked work stopped, it did not finish.

  Roles (`builder`, `verifier`, `reviewer`) are the same in both tracks; which agent serves
  each role depends on the track and is decided elsewhere.

  ## Queue order

  Priority, then how many still-open tasks each one unblocks, then `code`. Without the
  middle tie-breaker the order falls back to creation order, which in a mature phase puts
  a task that unblocks others behind them. Only declared dependencies are seen.
  """

  alias Factory.Tasks.Task

  defmodule Step do
    @moduledoc "A dispatchable unit: the task and the role that comes next."

    @type t :: %__MODULE__{task: Task.t(), role: atom()}

    defstruct [:task, :role]
  end

  @role_by_status %{
    ready: :builder,
    in_progress: :builder,
    in_testing: :verifier,
    in_review: :reviewer
  }

  @priority_order %{high: 0, medium: 1, low: 2}

  @type stuck :: %{
          task: Task.t(),
          missing: [%{code: String.t(), status: atom()}],
          unknown: [term()]
        }

  @type promotion :: %{promote: [Task.t()], stuck: [stuck()]}

  @doc "The role that serves each status. A status outside the table yields no step."
  @spec role_by_status() :: %{atom() => atom()}
  def role_by_status, do: @role_by_status

  @doc """
  Default limit of parallel builders, read from `config :factory, :max_builders` — the single
  source used by `next_steps/2`.
  """
  @spec default_max_builders() :: pos_integer()
  def default_max_builders, do: Application.get_env(:factory, :max_builders, 2)

  @doc """
  Which `backlog` tasks can become `ready`, and why the others cannot.

  Returns `{:error, {:cycle, path}}` when the graph has a cycle (a planning defect); `path`
  lists the codes in the order the loop closes. `stuck` separates `missing` (the dependency
  exists and is not finished) from `unknown` (it points to a task not in the list, which
  never resolves by itself).
  """
  @spec promote([Task.t()]) :: {:ok, promotion()} | {:error, term()}
  def promote(tasks) do
    with :ok <- check_loaded(tasks),
         :ok <- check_cycles(tasks) do
      {:ok, evaluate(tasks)}
    end
  end

  defp evaluate(tasks) do
    index = Map.new(tasks, &{&1.id, &1})
    replacements = Enum.group_by(tasks, & &1.replanned_from_id)

    tasks
    |> Enum.filter(&(&1.status == :backlog))
    |> Enum.reduce(%{promote: [], stuck: []}, fn task, acc ->
      classify(task, index, replacements, acc)
    end)
    |> then(&%{promote: Enum.reverse(&1.promote), stuck: Enum.reverse(&1.stuck)})
  end

  defp classify(task, index, replacements, acc) do
    {missing, unknown} = pending(task, index, replacements)

    if missing == [] and unknown == [] do
      %{acc | promote: [task | acc.promote]}
    else
      stuck = %{task: task, missing: missing, unknown: unknown}
      %{acc | stuck: [stuck | acc.stuck]}
    end
  end

  defp pending(task, index, replacements) do
    verdict = &classify_dependency(&1, index, replacements)
    by_kind = task.dependencies |> Enum.map(verdict) |> Enum.group_by(&elem(&1, 0))

    {
      by_kind |> Map.get(:missing, []) |> Enum.map(&elem(&1, 1)),
      by_kind |> Map.get(:unknown, []) |> Enum.map(&elem(&1, 1))
    }
  end

  defp classify_dependency(dependency, index, replacements) do
    case Map.fetch(index, dependency.depends_on_id) do
      :error -> {:unknown, dependency.depends_on_id}
      {:ok, required} -> verdict(required, replacements)
    end
  end

  defp verdict(required, replacements) do
    if satisfied?(required, replacements, []) do
      {:satisfied, required.code}
    else
      {:missing, %{code: required.code, status: required.status}}
    end
  end

  # `seen` stops the recursion on a replanning lineage that loops back on itself. It is a
  # list rather than a MapSet: lineages are short, and passing a literal MapSet to a private
  # function triggers a Dialyzer opacity warning.
  defp satisfied?(%Task{status: :done}, _replacements, _seen), do: true

  defp satisfied?(%Task{status: :cancelled} = task, replacements, seen) do
    if task.id in seen do
      false
    else
      children = Map.get(replacements, task.id, [])

      children != [] and
        Enum.all?(children, &satisfied?(&1, replacements, [task.id | seen]))
    end
  end

  defp satisfied?(_other, _replacements, _seen), do: false

  @doc """
  The next dispatchable steps, with the three parallelism rules applied:

  1. A verifier needs a quiet project: it goes alone, accompanied only by reviewers.
  2. Up to N builders in parallel, with disjoint `areas`. A task without declared `areas`
     may touch anything, so it runs alone among builders.
  3. Reviewers read the committed diff and run alongside anything.

  Accepts `:max_builders`; defaults to `default_max_builders/0`.
  """
  @spec next_steps([Task.t()], keyword()) :: [Step.t()]
  def next_steps(tasks, opts \\ []) do
    max = Keyword.get(opts, :max_builders, default_max_builders())
    candidates = tasks |> Enum.flat_map(&step_for/1) |> sort(dependents(tasks))

    reviewers = Enum.filter(candidates, &(&1.role == :reviewer))
    verifiers = Enum.filter(candidates, &(&1.role == :verifier))

    case verifiers do
      [first | _] -> reviewers ++ [first]
      [] -> reviewers ++ builders(candidates, max)
    end
  end

  defp step_for(task) do
    case Map.fetch(@role_by_status, task.status) do
      {:ok, role} -> [%Step{task: task, role: role}]
      :error -> []
    end
  end

  # How many still-open tasks wait on each task. Done and cancelled tasks do not count, or an
  # old task would look urgent forever.
  defp dependents(tasks) do
    tasks
    |> Enum.reject(&(&1.status in [:done, :cancelled]))
    |> Enum.flat_map(& &1.dependencies)
    |> Enum.frequencies_by(& &1.depends_on_id)
  end

  defp sort(candidates, dependents) do
    Enum.sort_by(candidates, fn %Step{task: task} ->
      {
        Map.get(@priority_order, task.priority, 1),
        -Map.get(dependents, task.id, 0),
        task.code
      }
    end)
  end

  defp builders(candidates, max) do
    candidates
    |> Enum.filter(&(&1.role == :builder))
    |> Enum.reduce_while({[], MapSet.new()}, fn step, {chosen, taken} ->
      choose(step, chosen, taken, max)
    end)
    |> then(fn {chosen, _taken} -> Enum.reverse(chosen) end)
  end

  defp choose(step, chosen, taken, max) do
    paths = MapSet.new(step.task.areas, & &1.path)

    cond do
      length(chosen) >= max ->
        {:halt, {chosen, taken}}

      # No declared `areas`: runs alone and ends the batch.
      MapSet.size(paths) == 0 ->
        if chosen == [],
          do: {:halt, {[step], taken}},
          else: {:halt, {chosen, taken}}

      MapSet.disjoint?(paths, taken) ->
        {:cont, {[step | chosen], MapSet.union(taken, paths)}}

      true ->
        {:cont, {chosen, taken}}
    end
  end

  # An unloaded association would raise far from the cause; callers must preload.
  defp check_loaded(tasks) do
    Enum.find_value(tasks, :ok, fn task ->
      cond do
        not is_list(task.dependencies) -> {:error, {:not_loaded, :dependencies}}
        not is_list(task.areas) -> {:error, {:not_loaded, :areas}}
        true -> nil
      end
    end)
  end

  # Three-colour depth-first search: meeting a node already on the stack closes a loop.
  defp check_cycles(tasks) do
    index = Map.new(tasks, &{&1.id, &1})

    Enum.reduce_while(tasks, {:ok, MapSet.new()}, fn task, {:ok, closed} ->
      case visit(task.id, index, closed, []) do
        {:ok, closed} -> {:cont, {:ok, closed}}
        {:cycle, path} -> {:halt, {:error, {:cycle, path}}}
      end
    end)
    |> case do
      {:ok, _closed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp visit(id, index, closed, stack) do
    cond do
      MapSet.member?(closed, id) ->
        {:ok, closed}

      id in stack ->
        {:cycle, cycle_path(id, stack, index)}

      true ->
        descend(id, index, closed, stack)
    end
  end

  defp descend(id, index, closed, stack) do
    neighbours =
      case Map.fetch(index, id) do
        {:ok, task} -> Enum.map(task.dependencies, & &1.depends_on_id)
        # An unknown dependency is not a cycle; `promote/1` reports it as `unknown`.
        :error -> []
      end

    Enum.reduce_while(neighbours, {:ok, closed}, fn neighbour, {:ok, acc} ->
      case visit(neighbour, index, acc, [id | stack]) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:cycle, path} -> {:halt, {:cycle, path}}
      end
    end)
    |> case do
      {:ok, closed} -> {:ok, MapSet.put(closed, id)}
      {:cycle, path} -> {:cycle, path}
    end
  end

  defp cycle_path(id, stack, index) do
    loop = stack |> Enum.reverse() |> Enum.drop_while(&(&1 != id))

    # The repeated `id` at the end shows where the loop closes; without it a two-task loop
    # would look like a plain chain.
    Enum.map(loop ++ [id], &code(&1, index))
  end

  defp code(id, index) do
    case Map.fetch(index, id) do
      {:ok, task} -> task.code
      :error -> "##{id}"
    end
  end
end

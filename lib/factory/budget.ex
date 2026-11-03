defmodule Factory.Budget do
  @moduledoc """
  Stops a round from STARTING work that does not fit. It never cuts an agent in flight:
  interrupting mid-way costs the same and delivers nothing, so no function here even sees a
  running dispatch — only what has been spent and what the next task should cost.

  Pure: no database, no process. The caller fetches the numbers and applies the decision.

  | cap | what it prevents |
  |---|---|
  | **round** | starting the next task if `spent + estimate` exceeds the cap |
  | **per task** | dispatching the SAME task again, even with round budget left |

  The per-task cap is a FRACTION of the round cap (`default_task_fraction/0`), so it follows
  whatever cap the user declares.

  The estimate calibrates itself: it is the mean cost per COMPLETED TASK measured in this job
  (never per stage, which would underestimate a whole task). With no measurement yet it falls
  back to the declared default of US$ 11.04 per completed task, an accounting estimate from
  token counts, not an invoice.
  """

  @default_estimate 11.04

  @default_task_fraction 0.3

  @typedoc "Why the dispatch cannot start."
  @type reason :: :budget | :task_budget

  @typedoc "The decision: start, or stop cleanly with a reason."
  @type decision :: :ok | {:stop, reason()}

  @doc "The declared default for when the job has measured nothing yet (US$ 11.04)."
  @spec default_estimate() :: float()
  def default_estimate, do: @default_estimate

  @doc "The fraction of the round cap used as the per-task cap when the caller declares none."
  @spec default_task_fraction() :: float()
  def default_task_fraction, do: @default_task_fraction

  @doc """
  How much the next task should cost: the mean of `completed_task_costs`, one total per
  completed task (all stages summed). An empty list falls back to the default.

  ## Examples

      iex> Factory.Budget.estimate_next_task([4.0, 6.0])
      5.0

      iex> Factory.Budget.estimate_next_task([])
      11.04
  """
  @spec estimate_next_task([number()]) :: float()
  def estimate_next_task([]), do: @default_estimate

  def estimate_next_task(completed_task_costs) do
    sum = Enum.sum(completed_task_costs)
    sum / length(completed_task_costs)
  end

  @doc "Does the next task FIT in the round cap? `spent + estimate <= cap`."
  @spec fits_round?(number(), number(), number()) :: boolean()
  def fits_round?(spent_so_far, next_estimate, round_cap) do
    spent_so_far + next_estimate <= round_cap
  end

  @doc """
  Decides whether the next task may start, given the round cap. Returns `:ok` or
  `{:stop, :budget}`; it is called BEFORE any dispatch exists, so nothing in flight is affected.

  ## Examples

      iex> Factory.Budget.check_round(60.0, 100.0, [10.0, 10.0])
      :ok

      iex> Factory.Budget.check_round(95.0, 100.0, [10.0])
      {:stop, :budget}
  """
  @spec check_round(number(), number(), [number()]) :: decision()
  def check_round(spent_so_far, round_cap, completed_task_costs \\ []) do
    estimate = estimate_next_task(completed_task_costs)

    if fits_round?(spent_so_far, estimate, round_cap) do
      :ok
    else
      {:stop, :budget}
    end
  end

  @doc """
  The cap a single task may consume: a fraction of the round cap. It catches a task eating most
  of the budget without delivering while the round still has room.

  ## Examples

      iex> Factory.Budget.task_cap(100.0)
      30.0

      iex> Factory.Budget.task_cap(100.0, 0.5)
      50.0
  """
  @spec task_cap(number(), number()) :: float()
  def task_cap(round_cap, fraction \\ @default_task_fraction) do
    round_cap * fraction
  end

  @doc "Does the task still fit in its own cap?"
  @spec fits_task?(number(), number()) :: boolean()
  def fits_task?(task_spent, task_cap) do
    task_spent < task_cap
  end

  @doc """
  Decides whether the SAME task may get another dispatch, independently of the round cap.

  ## Examples

      iex> Factory.Budget.check_task(20.0, 30.0)
      :ok

      iex> Factory.Budget.check_task(31.0, 30.0)
      {:stop, :task_budget}
  """
  @spec check_task(number(), number()) :: decision()
  def check_task(task_spent, task_cap) do
    if fits_task?(task_spent, task_cap) do
      :ok
    else
      {:stop, :task_budget}
    end
  end
end

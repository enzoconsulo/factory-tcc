defmodule Factory.BudgetTest do
  @moduledoc """
  The two caps, and the guarantee that neither interrupts anything in flight: the module is
  pure and no function receives a "running agent" parameter.
  """

  use ExUnit.Case, async: true

  alias Factory.Budget

  doctest Factory.Budget

  describe "round cap — prevents STARTING the next task" do
    test "fits: spent so far + estimate does not exceed the cap" do
      assert Budget.check_round(60.0, 100.0, [10.0, 10.0]) == :ok
    end

    test "exactly at the limit still fits" do
      assert Budget.check_round(90.0, 100.0, [10.0]) == :ok
    end

    test "does not fit: reports :budget" do
      assert Budget.check_round(95.0, 100.0, [10.0]) == {:stop, :budget}
    end

    test "the decision only looks BEFORE the dispatch: no in-flight parameter" do
      assert function_exported?(Budget, :check_round, 3)
    end
  end

  describe "per-task cap — cuts dispatches of the SAME task even with round budget left" do
    test "task_cap is a fraction of the round cap" do
      assert Budget.task_cap(100.0) == 100.0 * Budget.default_task_fraction()
    end

    test "accepts an explicit fraction" do
      assert Budget.task_cap(100.0, 0.5) == 50.0
    end

    test "a task within its own cap: :ok" do
      assert Budget.check_task(20.0, 30.0) == :ok
    end

    test "a task over its own cap stops, EVEN with plenty of round budget" do
      round_cap = 1000.0
      task_cap = Budget.task_cap(round_cap)

      task_spent = task_cap + 1

      assert Budget.check_round(5.0, round_cap, []) == :ok
      assert Budget.check_task(task_spent, task_cap) == {:stop, :task_budget}
    end
  end

  describe "the estimate uses cost per COMPLETED TASK measured in this job" do
    test "with measured tasks, the estimate is the MEAN of per-task totals" do
      assert Budget.estimate_next_task([4.0, 6.0]) == 5.0
      assert Budget.estimate_next_task([9.0]) == 9.0
    end

    test "a single expensive task is not discarded as noise" do
      assert Budget.estimate_next_task([31.28]) == 31.28
    end
  end

  describe "without own measurements, the estimate falls back to the declared default" do
    test "an empty list returns the default" do
      assert Budget.estimate_next_task([]) == 7.8241
    end

    test "default_estimate/0 exposes the same constant" do
      assert Budget.default_estimate() == 7.8241
    end
  end
end

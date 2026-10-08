defmodule Factory.Tasks.TransitionTest do
  @moduledoc """
  Locks the promise that status, report and cost are written together or not at all.

  The key test is "an error mid-transaction writes NOTHING": it checks the Multi's
  `changes_so_far` to show the task and cycle WERE applied inside the transaction, then the
  database to show none of it survived. It would fail if the Multi were replaced by
  sequential calls.
  """

  use Factory.DataCase, async: true

  alias Factory.Projects.Project
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Dispatch
  alias Factory.Tasks.Task
  alias Factory.Tasks.Transition
  alias Factory.Tasks.Usage

  setup do
    project =
      %Project{}
      |> Project.changeset(%{
        name: "project-#{System.unique_integer([:positive])}",
        path: "C:/tmp/p"
      })
      |> Repo.insert!()

    %{project: project}
  end

  defp task!(project, attrs) do
    default = %{
      project_id: project.id,
      code: "T-#{100 + System.unique_integer([:positive])}",
      title: "a task"
    }

    %Task{}
    |> Task.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  defp count(schema, task_id) do
    Repo.aggregate(from(c in schema, where: c.task_id == ^task_id), :count)
  end

  describe "a legal transition" do
    test "changes the status and returns the task in its new state", %{project: project} do
      task = task!(project, %{status: :backlog})

      assert {:ok, moved} = Transition.apply(task, :ready)
      assert moved.status == :ready
      assert Repo.get!(Task, task.id).status == :ready
    end

    test "accepts the id instead of the struct", %{project: project} do
      task = task!(project, %{status: :backlog})

      assert {:ok, %Task{status: :ready}} = Transition.apply(task.id, :ready)
    end

    test "reads the STATUS from the database, not from the struct at hand", %{project: project} do
      task = task!(project, %{status: :backlog})
      {:ok, _} = Transition.apply(task, :cancelled)

      # The struct still says `backlog`; the database says `cancelled`, a dead end.
      assert {:error, {:invalid_transition, :cancelled, :ready}} =
               Transition.apply(task, :ready)
    end

    test "reads ATTEMPTS from the database, not from the struct at hand", %{project: project} do
      task = task!(project, %{status: :ready, attempts: 0})

      {:ok, _} = Transition.apply(task, :in_progress)
      {:ok, _} = Transition.apply(task.id, :in_testing, role: "builder")

      # `task` froze at `attempts: 0`; incrementing from it would loop forever.
      assert {:ok, moved} = Transition.apply(task, :in_progress, role: "verifier")
      assert moved.attempts == 2
    end
  end

  describe "an illegal transition" do
    test "returns the named error", %{project: project} do
      task = task!(project, %{status: :backlog})

      assert {:error, {:invalid_transition, :backlog, :done}} =
               Transition.apply(task, :done)
    end

    test "writes nothing, not even the cycle that came with it", %{project: project} do
      task = task!(project, %{status: :backlog})

      assert {:error, {:invalid_transition, _, _}} =
               Transition.apply(task, :done, role: "reviewer", report: "approved")

      assert Repo.get!(Task, task.id).status == :backlog
      assert count(Cycle, task.id) == 0
    end

    test "a missing task returns a named error instead of crashing" do
      assert {:error, {:task_not_found, -1}} = Transition.apply(-1, :ready)
    end
  end

  describe "attempts — incremented by the system" do
    test "entering in_progress spends an attempt", %{project: project} do
      task = task!(project, %{status: :ready, attempts: 0})

      assert {:ok, moved} = Transition.apply(task, :in_progress)
      assert moved.attempts == 1
      assert Repo.get!(Task, task.id).attempts == 1
    end

    test "the three paths to in_progress spend an attempt alike", %{project: project} do
      for {from, attempts} <- [{:ready, 0}, {:in_testing, 1}, {:in_review, 1}] do
        task = task!(project, %{status: from, attempts: attempts})

        assert {:ok, moved} = Transition.apply(task, :in_progress)
        assert moved.attempts == attempts + 1, "coming from #{from}"
      end
    end

    test "no other transition touches attempts", %{project: project} do
      for {from, to} <- [
            {:backlog, :ready},
            {:in_progress, :in_testing},
            {:in_testing, :in_review},
            {:in_review, :done},
            {:in_testing, :blocked},
            {:in_review, :cancelled}
          ] do
        task = task!(project, %{status: from, attempts: 2})

        assert {:ok, moved} = Transition.apply(task, to)
        assert moved.attempts == 2, "#{from} -> #{to} should not spend an attempt"
      end
    end

    test "the increment is transactional: if the rest fails, no attempt is spent", %{
      project: project
    } do
      task = task!(project, %{status: :ready, attempts: 0})

      assert {:error, {:invalid, :usage_1, _}} =
               Transition.apply(task, :in_progress,
                 role: "verifier",
                 dispatch: %{provider: "Fake", model: "haiku-4.5"},
                 usages: [%{turn: 0}]
               )

      assert Repo.get!(Task, task.id).attempts == 0
    end

    # Detects an ASSIGNMENT of `attempts`, and nothing else. It is a write when the value
    # does not look like a type and is not a plain pass-through of the field for display
    # (`task.attempts`); `task.attempts + 1` is the only write. The whitespace sits INSIDE the
    # lookahead on purpose: with `attempts:\s*(?!...)` backtracking would make `\s*` match
    # nothing and the negation would never fire.
    @attempts_write ~r/\battempts:(?!\s*(?:[a-z_]+\(\)|[A-Z][\w.]*\.t\(\)|\{?[a-z_][\w]*\.attempts\b(?!\s*[-+*])))/

    test "there is ONE SINGLE place in production that writes attempts" do
      writers = Factory.Source.matching_production_files(@attempts_write)

      assert writers == ["lib/factory/tasks/transition.ex"]
    end

    test "the write detector works and does not pass on empty input" do
      assert "%{attempts: 1}" =~ @attempts_write
      assert "%{status: to, attempts: task.attempts + 1}" =~ @attempts_write

      refute "the system counts attempts" =~ @attempts_write
      refute "validate_number(:attempts, [])" =~ @attempts_write
      refute "`tasks.attempts` does not exist in the catalog" =~ @attempts_write
      refute "          attempts: non_neg_integer()" =~ @attempts_write
      refute "          attempts: Task.t()" =~ @attempts_write

      # A read-only pass-through for display is not a write.
      refute "      attempts: task.attempts," =~ @attempts_write
      refute "attempts: {task.attempts} ·" =~ @attempts_write
    end
  end

  describe "the three writes, in the same transaction" do
    test "status, cycle, dispatch and usages go in together", %{project: project} do
      task = task!(project, %{status: :in_progress, attempts: 1})

      assert {:ok, moved} =
               Transition.apply(task, :in_testing,
                 role: "builder",
                 outcome: "delivered",
                 report: "implemented X and ran the suite",
                 dispatch: %{provider: "ClaudeCLI", model: "sonnet-5", turns: 4},
                 usages: [
                   %{turn: 1, input_tokens: 100, cache_write_tokens: 9_000},
                   %{turn: 2, input_tokens: 40, cache_read_tokens: 9_000}
                 ]
               )

      assert moved.status == :in_testing

      cycle = Repo.one!(from(c in Cycle, where: c.task_id == ^task.id))
      assert cycle.role == "builder"
      assert cycle.outcome == "delivered"
      assert cycle.report =~ "implemented X"

      dispatch = Repo.one!(from(d in Dispatch, where: d.cycle_id == ^cycle.id))
      assert dispatch.provider == "ClaudeCLI"
      assert dispatch.turns == 4

      usages =
        Repo.all(from(u in Usage, where: u.dispatch_id == ^dispatch.id, order_by: u.turn))

      assert [%{turn: 1, cache_write_tokens: 9_000}, %{turn: 2, cache_read_tokens: 9_000}] =
               usages
    end

    test "without an explicit :turn, the list position becomes the turn number", %{
      project: project
    } do
      task = task!(project, %{status: :in_progress, attempts: 1})

      {:ok, _} =
        Transition.apply(task, :in_testing,
          role: "builder",
          dispatch: %{provider: "Fake", model: "haiku-4.5"},
          usages: [%{output_tokens: 1}, %{output_tokens: 2}, %{output_tokens: 3}]
        )

      turns = Repo.all(from(u in Usage, select: u.turn, order_by: u.turn))
      assert turns == [1, 2, 3]
    end

    test "handing the task to the builder does not invent a report", %{project: project} do
      # `ready -> in_progress` is a hand-off: nobody finished anything yet.
      task = task!(project, %{status: :ready})

      assert {:ok, _} = Transition.apply(task, :in_progress)
      assert count(Cycle, task.id) == 0
    end
  end

  describe "an error mid-transaction writes NOTHING" do
    test "the Multi applied task and cycle, and the database kept neither", %{
      project: project
    } do
      task = task!(project, %{status: :in_progress, attempts: 1})

      result =
        task.id
        |> Transition.build(:in_testing,
          role: "builder",
          report: "delivered",
          dispatch: %{provider: "ClaudeCLI", model: "sonnet-5"},
          usages: [%{turn: 1, input_tokens: 10}, %{turn: 0}]
        )
        |> Repo.transaction()

      assert {:error, {:usage, 2}, changeset, done} = result
      assert %{turn: [_ | _]} = errors_on(changeset)

      # Proof that there was something to undo:
      assert %{status: :in_testing} = done.task
      assert %{role: "builder"} = done.cycle
      assert %{provider: "ClaudeCLI"} = done.dispatch
      assert Map.has_key?(done, {:usage, 1})

      # Proof that it was undone:
      reloaded = Repo.get!(Task, task.id)
      assert reloaded.status == :in_progress
      assert reloaded.attempts == 1
      assert count(Cycle, task.id) == 0
      assert Repo.aggregate(Dispatch, :count) == 0
      assert Repo.aggregate(Usage, :count) == 0
    end

    test "an error from the DATABASE, not the changeset, rolls back too", %{project: project} do
      # The unique index `(task, number, role)` only fails at the database.
      task = task!(project, %{status: :in_testing, attempts: 1})

      Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "verifier"}))

      assert {:error, {:invalid, :cycle, changeset}} =
               Transition.apply(task, :in_review, role: "verifier", outcome: "approved")

      assert errors_on(changeset) != %{}
      assert Repo.get!(Task, task.id).status == :in_testing
      assert count(Cycle, task.id) == 1
    end
  end

  describe "option dependencies are checked before opening the transaction" do
    test "a dispatch without a role returns :dispatch_without_cycle", %{project: project} do
      task = task!(project, %{status: :ready})

      assert {:error, :dispatch_without_cycle} =
               Transition.apply(task, :in_progress,
                 dispatch: %{provider: "Fake", model: "haiku-4.5"}
               )

      assert Repo.get!(Task, task.id).status == :ready
    end

    test "role: nil counts as NO cycle, not as presence", %{project: project} do
      task = task!(project, %{status: :ready})

      assert {:error, :dispatch_without_cycle} =
               Transition.apply(task, :in_progress,
                 role: nil,
                 dispatch: %{provider: "Fake", model: "haiku-4.5"}
               )

      assert Repo.get!(Task, task.id).status == :ready
    end

    test "usages without a dispatch return :usage_without_dispatch", %{project: project} do
      task = task!(project, %{status: :ready})

      assert {:error, :usage_without_dispatch} =
               Transition.apply(task, :in_progress,
                 role: "builder",
                 usages: [%{turn: 1, input_tokens: 10}]
               )

      assert Repo.get!(Task, task.id).status == :ready
    end
  end

  describe "append/4 — steps added to an existing Multi" do
    test "outside work and the transition share the transaction", %{project: project} do
      task = task!(project, %{status: :backlog})
      other = task!(project, %{status: :backlog})

      assert {:ok, done} =
               Ecto.Multi.new()
               |> Ecto.Multi.update(:neighbour, Task.changeset(other, %{priority: :high}))
               |> Transition.append(task.id, :ready)
               |> Repo.transaction()

      assert done.neighbour.priority == :high
      assert done.task.status == :ready
    end

    test "an illegal transition also rolls back the outside work", %{project: project} do
      task = task!(project, %{status: :backlog})
      other = task!(project, %{status: :backlog})

      assert {:error, :checked, {:invalid_transition, :backlog, :done}, _} =
               Ecto.Multi.new()
               |> Ecto.Multi.update(:neighbour, Task.changeset(other, %{priority: :high}))
               |> Transition.append(task.id, :done)
               |> Repo.transaction()

      assert Repo.get!(Task, other.id).priority == :medium
    end

    test "build/3 is the empty-Multi case", %{project: project} do
      task = task!(project, %{status: :backlog})

      via_build = Transition.build(task.id, :ready)
      via_append = Transition.append(Ecto.Multi.new(), task.id, :ready)

      assert Ecto.Multi.to_list(via_build) |> Keyword.keys() ==
               Ecto.Multi.to_list(via_append) |> Keyword.keys()
    end
  end

  describe "the cycle number" do
    test "a rejecting report lands on the cycle that failed, not the next one", %{
      project: project
    } do
      task = task!(project, %{status: :in_testing, attempts: 1})

      assert {:ok, moved} =
               Transition.apply(task, :in_progress,
                 role: "verifier",
                 outcome: "rejected",
                 report: "criterion 2 does not pass"
               )

      assert moved.attempts == 2

      cycle = Repo.one!(from(c in Cycle, where: c.task_id == ^task.id))
      assert cycle.number == 1
    end

    test "the three roles of one pass share the number", %{project: project} do
      task = task!(project, %{status: :ready})

      {:ok, task} = Transition.apply(task, :in_progress)
      {:ok, task} = Transition.apply(task, :in_testing, role: "builder")
      {:ok, task} = Transition.apply(task, :in_review, role: "verifier")
      {:ok, task} = Transition.apply(task, :done, role: "reviewer")

      numbers =
        Repo.all(from(c in Cycle, where: c.task_id == ^task.id, select: {c.role, c.number}))

      assert Enum.sort(numbers) == [{"builder", 1}, {"reviewer", 1}, {"verifier", 1}]
      assert task.attempts == 1
    end
  end

  describe "the whole path" do
    test "the task goes through six states, is rejected, reworked and done", %{
      project: project
    } do
      task = task!(project, %{status: :backlog})

      {:ok, task} = Transition.apply(task, :ready)
      {:ok, task} = Transition.apply(task, :in_progress)
      {:ok, task} = Transition.apply(task, :in_testing, role: "builder")

      {:ok, task} =
        Transition.apply(task, :in_progress, role: "verifier", outcome: "rejected")

      assert task.attempts == 2

      {:ok, task} = Transition.apply(task, :in_testing, role: "builder")
      {:ok, task} = Transition.apply(task, :in_review, role: "verifier")
      {:ok, task} = Transition.apply(task, :done, role: "reviewer")

      assert task.status == :done
      assert task.attempts == 2

      # The second cycle is separable from the first, so each pass's cost can be queried.
      per_cycle =
        Repo.all(from(c in Cycle, where: c.task_id == ^task.id, select: {c.number, c.role}))

      assert Enum.sort(per_cycle) == [
               {1, "builder"},
               {1, "verifier"},
               {2, "builder"},
               {2, "reviewer"},
               {2, "verifier"}
             ]
    end

    test "exhausting cycles blocks, and replanning cancels the original", %{project: project} do
      task = task!(project, %{status: :in_testing, attempts: 3})

      {:ok, task} =
        Transition.apply(task, :blocked,
          role: "system",
          outcome: "cycles exhausted"
        )

      assert task.status == :blocked

      {:ok, task} = Transition.apply(task, :cancelled)
      assert task.status == :cancelled

      # Nothing leaves it anymore.
      assert {:error, {:invalid_transition, :cancelled, :ready}} =
               Transition.apply(task, :ready)
    end
  end
end

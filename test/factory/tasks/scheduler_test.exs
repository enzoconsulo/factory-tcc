defmodule Factory.Tasks.SchedulerTest do
  @moduledoc """
  Promotion, ordering and parallelism rules.

  This file deliberately does not use `DataCase`: `Scheduler` promises to be pure, and tasks
  here are structs built by hand, so the whole file runs in milliseconds.
  """

  use ExUnit.Case, async: true

  alias Factory.Tasks.Area
  alias Factory.Tasks.Dependency
  alias Factory.Tasks.Scheduler
  alias Factory.Tasks.Scheduler.Step
  alias Factory.Tasks.Task

  # The `id` derives from the code, so tests talk in "T-001" and the graph in integers. A
  # replanning suffix becomes a digit ("T-001a" is 11, "T-001b" is 12).
  defp identifier("T-" <> rest) do
    {digits, suffix} = String.split_at(rest, 3)
    base = String.to_integer(digits)

    case suffix do
      "" -> base
      <<letter>> -> base * 10 + (letter - ?a + 1)
    end
  end

  defp task(code, attrs \\ []) do
    %Task{
      id: identifier(code),
      code: code,
      title: code,
      status: Keyword.get(attrs, :status, :backlog),
      priority: Keyword.get(attrs, :priority, :medium),
      attempts: Keyword.get(attrs, :attempts, 0),
      replanned_from_id: Keyword.get(attrs, :replanned_from),
      dependencies:
        attrs
        |> Keyword.get(:depends_on, [])
        |> Enum.map(&%Dependency{depends_on_id: &1}),
      areas:
        attrs
        |> Keyword.get(:areas, [])
        |> Enum.map(&%Area{path: &1})
    }
  end

  defp codes(tasks), do: Enum.map(tasks, & &1.code)
  defp step_codes(steps), do: Enum.map(steps, & &1.task.code)

  describe "promote" do
    test "promotes when every dependency is done" do
      tasks = [
        task("T-001", status: :done),
        task("T-002", status: :done),
        task("T-003", depends_on: [1, 2])
      ]

      assert {:ok, %{promote: promote, stuck: []}} = Scheduler.promote(tasks)
      assert codes(promote) == ["T-003"]
    end

    test "does not promote with a pending dependency, and says which" do
      tasks = [
        task("T-001", status: :done),
        task("T-002", status: :in_progress),
        task("T-003", depends_on: [1, 2])
      ]

      assert {:ok, %{promote: [], stuck: [stuck]}} = Scheduler.promote(tasks)
      assert stuck.task.code == "T-003"
      assert stuck.missing == [%{code: "T-002", status: :in_progress}]
      assert stuck.unknown == []
    end

    test "an unknown dependency is kept apart from a pending one" do
      tasks = [
        task("T-001", status: :in_testing),
        task("T-003", depends_on: [1, 999])
      ]

      assert {:ok, %{stuck: [stuck]}} = Scheduler.promote(tasks)
      assert [%{code: "T-001"}] = stuck.missing
      assert stuck.unknown == [999]
    end

    test "a task without dependencies is promoted" do
      assert {:ok, %{promote: promote}} = Scheduler.promote([task("T-001")])
      assert codes(promote) == ["T-001"]
    end

    test "only looks at backlog" do
      tasks = [
        task("T-001", status: :done),
        task("T-002", status: :ready, depends_on: [1]),
        task("T-003", status: :in_review)
      ]

      assert {:ok, %{promote: [], stuck: []}} = Scheduler.promote(tasks)
    end
  end

  describe "promote — cancelled dependencies" do
    test "a cancelled task WITH a done replacement satisfies" do
      # T-001 exhausted its cycles, was replanned into T-001a, and the original was cancelled.
      tasks = [
        task("T-001", status: :cancelled),
        task("T-001a", status: :done, replanned_from: 1),
        task("T-002", depends_on: [1])
      ]

      assert {:ok, %{promote: promote, stuck: []}} = Scheduler.promote(tasks)
      assert codes(promote) == ["T-002"]
    end

    test "a cancelled task WITHOUT any replacement still blocks" do
      tasks = [
        task("T-001", status: :cancelled),
        task("T-002", depends_on: [1])
      ]

      assert {:ok, %{promote: [], stuck: [stuck]}} = Scheduler.promote(tasks)
      assert stuck.missing == [%{code: "T-001", status: :cancelled}]
    end

    test "ALL replacements must be done, not just one" do
      tasks = [
        task("T-001", status: :cancelled),
        task("T-001a", status: :done, replanned_from: 1),
        task("T-001b", status: :in_progress, replanned_from: 1),
        task("T-002", depends_on: [1])
      ]

      assert {:ok, %{promote: [], stuck: [%{task: %{code: "T-002"}}]}} =
               Scheduler.promote(tasks)
    end

    test "the lineage is recursive: a replanned replacement resolves through its own" do
      tasks = [
        task("T-001", status: :cancelled),
        task("T-001a", status: :cancelled, replanned_from: 1),
        task("T-001b", status: :done, replanned_from: 11),
        task("T-002", depends_on: [1])
      ]

      assert {:ok, %{promote: promote}} = Scheduler.promote(tasks)
      assert codes(promote) == ["T-002"]
    end

    test "a replanning lineage that loops back does not hang the analysis" do
      tasks = [
        task("T-001", status: :cancelled, replanned_from: 11),
        task("T-001a", status: :cancelled, replanned_from: 1),
        task("T-002", depends_on: [1])
      ]

      assert {:ok, %{promote: [], stuck: [_]}} = Scheduler.promote(tasks)
    end
  end

  describe "promote — blocked does not satisfy" do
    test "a blocked dependency blocks, and its status appears in the report" do
      tasks = [
        task("T-001", status: :blocked),
        task("T-002", depends_on: [1])
      ]

      assert {:ok, %{promote: [], stuck: [stuck]}} = Scheduler.promote(tasks)
      assert stuck.missing == [%{code: "T-001", status: :blocked}]
    end

    test "blocked with a done replacement ALSO blocks: only cancelled has that way out" do
      tasks = [
        task("T-001", status: :blocked),
        task("T-001a", status: :done, replanned_from: 1),
        task("T-002", depends_on: [1])
      ]

      assert {:ok, %{promote: []}} = Scheduler.promote(tasks)
    end
  end

  describe "promote — dependency cycles" do
    test "a two-task cycle is detected and reported with its path" do
      tasks = [
        task("T-001", depends_on: [2]),
        task("T-002", depends_on: [1])
      ]

      assert {:error, {:cycle, path}} = Scheduler.promote(tasks)
      assert "T-001" in path
      assert "T-002" in path
      # The repeated code at the end shows WHERE the loop closes.
      assert List.first(path) == List.last(path)
    end

    test "a three-task cycle too" do
      tasks = [
        task("T-001", depends_on: [2]),
        task("T-002", depends_on: [3]),
        task("T-003", depends_on: [1])
      ]

      assert {:error, {:cycle, path}} = Scheduler.promote(tasks)
      assert length(path) == 4
    end

    test "a diamond graph is NOT a cycle" do
      tasks = [
        task("T-001", status: :done),
        task("T-002", status: :done, depends_on: [1]),
        task("T-003", status: :done, depends_on: [1]),
        task("T-004", depends_on: [2, 3])
      ]

      assert {:ok, %{promote: promote}} = Scheduler.promote(tasks)
      assert codes(promote) == ["T-004"]
    end

    test "an unknown dependency is not mistaken for a cycle" do
      tasks = [task("T-001", depends_on: [999])]

      assert {:ok, %{stuck: [%{unknown: [999]}]}} = Scheduler.promote(tasks)
    end
  end

  describe "promote — the purity contract" do
    test "an unloaded association returns a named error, not Protocol.UndefinedError" do
      raw = %Task{id: 1, code: "T-001", status: :backlog}

      assert {:error, {:not_loaded, :dependencies}} = Scheduler.promote([raw])
    end

    test "unloaded areas too" do
      raw = %Task{id: 1, code: "T-001", status: :backlog, dependencies: []}

      assert {:error, {:not_loaded, :areas}} = Scheduler.promote([raw])
    end

    test "the module references neither Repo nor Ecto.Query" do
      source = File.read!("lib/factory/tasks/scheduler.ex")

      for forbidden <- ["Repo", "Ecto.Query", "from("] do
        refute source =~ forbidden, "Scheduler references #{forbidden}: it promises to be pure."
      end
    end
  end

  describe "next_steps — the three parallelism rules" do
    test "maps each status to the role that serves it" do
      tasks = [
        task("T-001", status: :ready),
        task("T-002", status: :in_testing),
        task("T-003", status: :in_review)
      ]

      roles = tasks |> Scheduler.next_steps() |> Enum.map(& &1.role) |> Enum.sort()
      assert roles == [:reviewer, :verifier]
    end

    test "a verifier runs ALONE: no builder goes with it" do
      tasks = [
        task("T-001", status: :ready, areas: ["a.ex"]),
        task("T-002", status: :in_testing)
      ]

      assert [%Step{role: :verifier, task: %{code: "T-002"}}] = Scheduler.next_steps(tasks)
    end

    test "one verifier at a time, even with two tasks in testing" do
      tasks = [
        task("T-001", status: :in_testing),
        task("T-002", status: :in_testing)
      ]

      assert [%Step{role: :verifier}] = Scheduler.next_steps(tasks)
    end

    test "a reviewer goes along with the verifier: it reads the committed diff" do
      tasks = [
        task("T-001", status: :in_review),
        task("T-002", status: :in_testing)
      ]

      roles = tasks |> Scheduler.next_steps() |> Enum.map(& &1.role)
      assert roles == [:reviewer, :verifier]
    end

    test "up to 3 parallel builders with disjoint areas, when configured" do
      tasks = [
        task("T-001", status: :ready, areas: ["a.ex"]),
        task("T-002", status: :ready, areas: ["b.ex"]),
        task("T-003", status: :ready, areas: ["c.ex"]),
        task("T-004", status: :ready, areas: ["d.ex"])
      ]

      assert step_codes(Scheduler.next_steps(tasks, max_builders: 3)) ==
               ["T-001", "T-002", "T-003"]
    end

    test "without configuration, the default is 2 builders" do
      tasks = [
        task("T-001", status: :ready, areas: ["a.ex"]),
        task("T-002", status: :ready, areas: ["b.ex"]),
        task("T-003", status: :ready, areas: ["c.ex"])
      ]

      assert step_codes(Scheduler.next_steps(tasks)) == ["T-001", "T-002"]
    end

    test "shared areas: the second stays out, and the third goes in" do
      tasks = [
        task("T-001", status: :ready, areas: ["a.ex", "b.ex"]),
        task("T-002", status: :ready, areas: ["b.ex"]),
        task("T-003", status: :ready, areas: ["c.ex"])
      ]

      assert step_codes(Scheduler.next_steps(tasks)) == ["T-001", "T-003"]
    end

    test "a task WITHOUT declared areas runs alone among builders" do
      tasks = [
        task("T-001", status: :ready),
        task("T-002", status: :ready, areas: ["b.ex"])
      ]

      assert step_codes(Scheduler.next_steps(tasks)) == ["T-001"]
    end

    test "terminal states and backlog yield no step" do
      tasks = [
        task("T-001", status: :backlog),
        task("T-002", status: :done),
        task("T-003", status: :blocked),
        task("T-004", status: :cancelled)
      ]

      assert Scheduler.next_steps(tasks) == []
    end

    test "the builder limit is adjustable" do
      tasks =
        for n <- 1..5, do: task("T-00#{n}", status: :ready, areas: ["#{n}.ex"])

      assert length(Scheduler.next_steps(tasks, max_builders: 2)) == 2
    end
  end

  describe "next_steps — queue order" do
    test "priority rules" do
      tasks = [
        task("T-001", status: :ready, priority: :low, areas: ["a.ex"]),
        task("T-002", status: :ready, priority: :high, areas: ["b.ex"]),
        task("T-003", status: :ready, priority: :medium, areas: ["c.ex"])
      ]

      # Explicit max_builders: 3; this test is about order, not the limit.
      assert step_codes(Scheduler.next_steps(tasks, max_builders: 3)) ==
               ["T-002", "T-003", "T-001"]
    end

    test "among equals, the one unblocking more tasks comes first, not the lowest code" do
      tasks = [
        task("T-001", status: :ready, areas: ["a.ex"]),
        task("T-002", status: :ready, areas: ["b.ex"]),
        task("T-003", depends_on: [2]),
        task("T-004", depends_on: [2])
      ]

      assert ["T-002", "T-001"] = step_codes(Scheduler.next_steps(tasks))
    end

    test "priority still rules: high without dependents beats medium with many" do
      tasks = [
        task("T-001", status: :ready, priority: :high, areas: ["a.ex"]),
        task("T-002", status: :ready, priority: :medium, areas: ["b.ex"]),
        task("T-003", depends_on: [2]),
        task("T-004", depends_on: [2])
      ]

      assert ["T-001", "T-002"] = step_codes(Scheduler.next_steps(tasks))
    end

    test "a closed dependent does not count as waiting" do
      tasks = [
        task("T-001", status: :ready, areas: ["a.ex"]),
        task("T-002", status: :ready, areas: ["b.ex"]),
        task("T-003", status: :done, depends_on: [2]),
        task("T-004", status: :cancelled, depends_on: [2])
      ]

      assert ["T-001", "T-002"] = step_codes(Scheduler.next_steps(tasks))
    end

    test "a full tie falls back to the code, deterministically" do
      tasks = [
        task("T-003", status: :ready, areas: ["c.ex"]),
        task("T-001", status: :ready, areas: ["a.ex"]),
        task("T-002", status: :ready, areas: ["b.ex"])
      ]

      opts = [max_builders: 3]

      assert step_codes(Scheduler.next_steps(tasks, opts)) == ["T-001", "T-002", "T-003"]
      assert Scheduler.next_steps(tasks, opts) == Scheduler.next_steps(Enum.reverse(tasks), opts)
    end
  end
end

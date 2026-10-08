defmodule Factory.PlanTaskTest do
  @moduledoc """
  Locks `mix factory.plan`, the only human step: it creates or reuses the project, calls
  `Factory.Planner.plan/3` and promotes to `ready` every new task without pending
  dependencies.
  """

  use Factory.DataCase, async: true

  alias Factory.Projects.Project
  alias Factory.Provider.Fake
  alias Factory.Repo
  alias Factory.Tasks.Task
  alias Mix.Tasks.Factory.Plan

  setup do
    root = Path.join(System.tmp_dir!(), "factory-plan-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, name: "project-#{System.unique_integer([:positive])}"}
  end

  defp task_json(id, opts \\ []) do
    %{
      "id" => id,
      "title" => Keyword.get(opts, :title, "task #{id}"),
      "goal" => Keyword.get(opts, :goal, "part #{id} of the system exists"),
      "context" => Keyword.get(opts, :context, "builds on what already exists"),
      "areas" => Keyword.get(opts, :areas, ["lib/example_#{id}.ex"]),
      "criteria" =>
        Keyword.get(opts, :criteria, [
          %{
            "text" => "part #{id} works",
            "command" => "mix test test/example_#{id}_test.exs"
          }
        ]),
      "dependencies" => Keyword.get(opts, :dependencies, [])
    }
  end

  defp valid_plan(count) do
    tasks = Enum.map(1..count, &task_json/1)
    %{"tasks" => tasks}
  end

  defp script!(map) do
    text = "Here is the plan:\n\n```json\n#{Jason.encode!(map)}\n```\n"

    {:ok, needle} =
      Fake.start(script: [Fake.response(blocks: [%{type: :text, text: text}])])

    needle
  end

  describe "plan/3 — valid plan" do
    test "creates the project and stores the tasks", %{root: root, name: name} do
      needle = script!(valid_plan(8))

      assert {:ok, report} = Plan.plan("build module X", name, needle: needle, path: root)

      assert report.tasks == 8
      assert report.project.name == name
      assert File.dir?(root)
      assert Repo.get_by(Project, name: name)
    end

    test "at least one task without dependencies becomes ready", %{root: root, name: name} do
      tasks =
        Enum.map(1..8, fn
          1 -> task_json(1, dependencies: [2])
          id -> task_json(id)
        end)

      needle = script!(%{"tasks" => tasks})

      assert {:ok, report} = Plan.plan("build module Y", name, needle: needle, path: root)

      assert report.ready > 0

      project = Repo.get_by(Project, name: name)

      ready =
        Task
        |> Ecto.Query.where(project_id: ^project.id, status: :ready)
        |> Repo.all()

      assert length(ready) == report.ready
      assert ready != []
    end

    test "a task with a pending dependency does not become ready", %{root: root, name: name} do
      tasks =
        Enum.map(1..8, fn
          1 -> task_json(1, dependencies: [2])
          id -> task_json(id)
        end)

      needle = script!(%{"tasks" => tasks})

      assert {:ok, report} = Plan.plan("build module W", name, needle: needle, path: root)

      # 8 tasks, one of which (#1) depends on another still in backlog: at most 7 ready.
      assert report.ready < report.tasks
    end

    test "an existing project is reused, not duplicated", %{root: root, name: name} do
      File.mkdir_p!(root)

      project =
        %Project{} |> Project.changeset(%{name: name, path: root}) |> Repo.insert!()

      needle = script!(valid_plan(8))

      assert {:ok, report} = Plan.plan("continue the project", name, needle: needle, path: root)

      assert report.project.id == project.id
      assert Repo.aggregate(Ecto.Query.where(Project, name: ^name), :count) == 1
    end
  end

  describe "plan/3 — invalid plan" do
    test "the planner's error propagates and no task is created", %{root: root, name: name} do
      needle = script!(valid_plan(3))

      assert {:error, _reason} = Plan.plan("small request", name, needle: needle, path: root)

      project = Repo.get_by(Project, name: name)
      assert Repo.aggregate(Ecto.Query.where(Task, project_id: ^project.id), :count) == 0
    end
  end

  describe "run/1 — CLI usage" do
    test "without --project, refuses with a clear message (Mix.Error)" do
      assert_raise Mix.Error, ~r/--project/, fn ->
        Plan.run(["test request"])
      end
    end

    test "without the request, refuses with a clear message" do
      assert_raise Mix.Error, ~r/usage:/, fn ->
        Plan.run(["--project", "some-name"])
      end
    end
  end
end

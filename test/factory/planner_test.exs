defmodule Factory.PlannerTest do
  @moduledoc """
  A natural-language request becomes a graph of 8 to 12 tasks, written in a single
  transaction — or nothing is written.
  """

  use Factory.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Factory.Planner
  alias Factory.Projects.Project
  alias Factory.Provider.Fake
  alias Factory.Tasks.Task

  setup do
    root = Path.join(System.tmp_dir!(), "planner-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    project =
      %Project{}
      |> Project.changeset(%{
        name: "project-#{System.unique_integer([:positive])}",
        path: root
      })
      |> Repo.insert!()

    %{project: project}
  end

  defp task_json(id, opts \\ []) do
    %{
      "id" => id,
      "title" => Keyword.get(opts, :title, "task #{id}"),
      "goal" => Keyword.get(opts, :goal, "part #{id} of the system exists"),
      "context" => Keyword.get(opts, :context, "depends on what already exists"),
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

  defp json_block(map) do
    %{type: :text, text: "Here is the plan:\n\n```json\n#{Jason.encode!(map)}\n```\n"}
  end

  defp script!(map_or_text) do
    blocks =
      case map_or_text do
        text when is_binary(text) -> [%{type: :text, text: text}]
        map -> [json_block(map)]
      end

    {:ok, needle} = Fake.start(script: [Fake.response(blocks: blocks)])
    needle
  end

  defp count_tasks(project) do
    Repo.aggregate(from(t in Task, where: t.project_id == ^project.id), :count)
  end

  describe "a valid plan" do
    test "writes 8 to 12 tasks in a single transaction", %{project: project} do
      needle = script!(valid_plan(9))

      assert {:ok, %{project: ^project, tasks: tasks}} =
               Planner.plan("build module X", project, needle: needle)

      assert length(tasks) == 9
      assert count_tasks(project) == 9
      assert Enum.all?(tasks, &(&1.project_id == project.id))
      assert Enum.all?(tasks, &String.match?(&1.code, ~r/^T-\d{3,}$/))
    end

    test "every task carries its areas and criteria", %{project: project} do
      needle = script!(valid_plan(8))

      assert {:ok, %{tasks: tasks}} =
               Planner.plan("build module Y", project, needle: needle)

      Enum.each(tasks, fn task ->
        task = Repo.preload(task, [:areas, :criteria])
        assert task.areas != []
        assert task.criteria != []
        assert Enum.all?(task.areas, &(not String.ends_with?(&1.path, "/")))
      end)
    end

    test "JSON dependencies become Factory.Tasks.Dependency rows", %{project: project} do
      tasks =
        Enum.map(1..8, fn
          1 -> task_json(1, dependencies: [2])
          id -> task_json(id)
        end)

      needle = script!(%{"tasks" => tasks})

      assert {:ok, %{tasks: written}} =
               Planner.plan("build module Z", project, needle: needle)

      task_1 = written |> List.first() |> Repo.preload(:dependencies)
      assert length(task_1.dependencies) == 1
    end

    test "generated codes continue the project's existing numbering", %{project: project} do
      %Task{}
      |> Task.changeset(%{
        project_id: project.id,
        code: "T-005",
        title: "earlier task"
      })
      |> Repo.insert!()

      needle = script!(valid_plan(8))

      assert {:ok, %{tasks: tasks}} =
               Planner.plan("continue the project", project, needle: needle)

      codes = Enum.map(tasks, & &1.code) |> Enum.sort()
      assert codes == Enum.map(6..13, &"T-#{String.pad_leading(to_string(&1), 3, "0")}")
    end
  end

  describe "a response that does not end in valid JSON" do
    test "no json code block — error, nothing written", %{project: project} do
      needle = script!("sorry, I cannot plan this without more information.")

      assert {:error, _reason} = Planner.plan("vague request", project, needle: needle)
      assert count_tasks(project) == 0
    end

    test "malformed JSON inside the block — error, nothing written", %{project: project} do
      needle = script!("```json\n{invalid\n```")

      assert {:error, _reason} = Planner.plan("request", project, needle: needle)
      assert count_tasks(project) == 0
    end

    test "a provider error propagates without writing anything", %{project: project} do
      {:ok, needle} = Fake.start(script: [])

      assert {:error, _reason} = Planner.plan("request", project, needle: needle)
      assert count_tasks(project) == 0
    end
  end

  describe "an invalid plan — no partial rows in the database" do
    test "fewer than 8 tasks is refused", %{project: project} do
      needle = script!(valid_plan(3))

      assert {:error, _reason} = Planner.plan("small request", project, needle: needle)
      assert count_tasks(project) == 0
    end

    test "more than 12 tasks is refused", %{project: project} do
      needle = script!(valid_plan(13))

      assert {:error, _reason} = Planner.plan("large request", project, needle: needle)
      assert count_tasks(project) == 0
    end

    test "an area ending in a slash (directory) is refused", %{project: project} do
      tasks =
        Enum.map(1..8, fn
          1 -> task_json(1, areas: ["lib/folder/"])
          id -> task_json(id)
        end)

      needle = script!(%{"tasks" => tasks})

      assert {:error, _reason} = Planner.plan("request", project, needle: needle)
      assert count_tasks(project) == 0
    end

    test "a dependency cycle is refused", %{project: project} do
      tasks =
        Enum.map(1..8, fn
          1 -> task_json(1, dependencies: [2])
          2 -> task_json(2, dependencies: [1])
          id -> task_json(id)
        end)

      needle = script!(%{"tasks" => tasks})

      assert {:error, reason} = Planner.plan("request", project, needle: needle)
      assert reason |> inspect() =~ "cycle"
      assert count_tasks(project) == 0
    end

    test "a dependency on an unknown id is refused", %{project: project} do
      tasks =
        Enum.map(1..8, fn
          1 -> task_json(1, dependencies: [99])
          id -> task_json(id)
        end)

      needle = script!(%{"tasks" => tasks})

      assert {:error, _reason} = Planner.plan("request", project, needle: needle)
      assert count_tasks(project) == 0
    end
  end

  describe "the planner doctrine" do
    test "states the exact expected response format" do
      text =
        [:code.priv_dir(:factory), "doctrine", "planner.md"]
        |> Path.join()
        |> File.read!()

      assert text =~ "```json"
      assert text =~ "dependencies"
      assert text =~ "report_result"
    end
  end
end

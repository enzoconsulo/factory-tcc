defmodule Factory.Publishing.MarkdownTest do
  @moduledoc """
  The generated markdown has the frontmatter and the seven sections, and two generations of
  the same task produce identical bytes.
  """

  use Factory.DataCase, async: true

  alias Factory.Projects.Project
  alias Factory.Projects.Specialist
  alias Factory.Publishing.Markdown
  alias Factory.Tasks.Area
  alias Factory.Tasks.Criterion
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Dependency
  alias Factory.Tasks.Task

  @preloads [
    :project,
    :specialist,
    :replanned_from,
    :areas,
    :criteria,
    :cycles,
    dependencies: :depends_on
  ]

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

  defp task!(project, attrs \\ %{}) do
    defaults = %{
      project_id: project.id,
      code: "T-#{100 + System.unique_integer([:positive])}",
      title: "a task",
      goal: "what must exist when done",
      context: "what the builder needs to know"
    }

    %Task{}
    |> Task.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp reload(task), do: task |> Repo.reload!() |> Repo.preload(@preloads)

  defp area!(task, path) do
    %Area{} |> Area.changeset(%{task_id: task.id, path: path}) |> Repo.insert!()
  end

  defp criterion!(task, attrs) do
    %Criterion{}
    |> Criterion.changeset(Map.put(attrs, :task_id, task.id))
    |> Repo.insert!()
  end

  defp cycle!(task, attrs) do
    %Cycle{}
    |> Cycle.changeset(Map.merge(%{task_id: task.id, number: 1}, attrs))
    |> Repo.insert!()
  end

  describe "the seven sections" do
    test "the markdown has the frontmatter and the seven sections", %{project: project} do
      task = task!(project) |> reload()

      content = Markdown.generate(task)

      assert String.starts_with?(content, "---\n")
      assert content =~ "id: #{task.code}"
      assert content =~ "title: a task"
      assert content =~ "project: #{project.name}"
      assert content =~ "status: backlog"
      assert content =~ "priority: medium"
      assert content =~ "attempts: 0"

      for section <- [
            "## Goal",
            "## Context",
            "## Acceptance criteria",
            "## Execution notes",
            "## Verification",
            "## Conformance",
            "## Review"
          ] do
        assert content =~ section
      end
    end

    test "ends with exactly one newline", %{project: project} do
      task = task!(project) |> reload()

      content = Markdown.generate(task)

      refute String.ends_with?(content, "\n\n")
      assert String.ends_with?(content, "\n")
    end

    test "an underscore status becomes a hyphen in the frontmatter", %{project: project} do
      task = task!(project, %{status: :in_progress}) |> reload()

      assert Markdown.generate(task) =~ "status: in-progress"
    end

    test "areas and dependencies are SORTED, not in insertion order", %{project: project} do
      target = task!(project)
      dep_b = task!(project, %{code: "T-#{200 + System.unique_integer([:positive])}"})
      dep_a = task!(project, %{code: "T-001"})

      area!(target, "lib/z.ex")
      area!(target, "lib/a.ex")

      %Dependency{}
      |> Dependency.changeset(%{task_id: target.id, depends_on_id: dep_b.id})
      |> Repo.insert!()

      %Dependency{}
      |> Dependency.changeset(%{task_id: target.id, depends_on_id: dep_a.id})
      |> Repo.insert!()

      content = target |> reload() |> Markdown.generate()

      assert content =~ "areas: [lib/a.ex, lib/z.ex]"
      assert content =~ "dependencies: [T-001, #{dep_b.code}]"
    end

    test "without areas or dependencies, the lists are empty", %{project: project} do
      task = task!(project) |> reload()

      content = Markdown.generate(task)

      assert content =~ "areas: []"
      assert content =~ "dependencies: []"
    end

    test "an active specialist becomes the `agent:` line; absent, it is omitted", %{
      project: project
    } do
      without_specialist = task!(project) |> reload()
      refute Markdown.generate(without_specialist) =~ "agent:"

      specialist =
        %Specialist{}
        |> Specialist.changeset(%{
          project_id: project.id,
          identifier: "specialist-x",
          name: "Specialist X",
          prompt: "do X"
        })
        |> Repo.insert!()

      with_specialist =
        task!(project, %{specialist_id: specialist.id}) |> reload()

      assert Markdown.generate(with_specialist) =~ "agent: specialist-x"
    end

    test "a replanned task carries `replanned-from:` with the origin's code", %{project: project} do
      origin = task!(project)
      replacement = task!(project, %{replanned_from_id: origin.id}) |> reload()

      assert Markdown.generate(replacement) =~ "replanned-from: #{origin.code}"
    end

    test "a criterion with a command gets the `verify:` line; without, only the text", %{
      project: project
    } do
      task = task!(project)
      criterion!(task, %{text: "first criterion", command: "mix test", level: :executed})
      criterion!(task, %{text: "second criterion, no command"})

      content = task |> reload() |> Markdown.generate()

      assert content =~ "- [ ] first criterion\n      `verify: mix test`"
      assert content =~ "- [ ] second criterion, no command"
    end

    test "criteria come out in creation order (by id)", %{project: project} do
      task = task!(project)
      criterion!(task, %{text: "z created first"})
      criterion!(task, %{text: "a created later"})

      content = task |> reload() |> Markdown.generate()

      z_position = :binary.match(content, "z created first") |> elem(0)
      a_position = :binary.match(content, "a created later") |> elem(0)

      assert z_position < a_position
    end
  end

  describe "cycles become the report sections" do
    test "a builder cycle feeds Execution notes", %{project: project} do
      task = task!(project)
      cycle!(task, %{role: "builder", report: "## summary\ndid the basics"})

      content = task |> reload() |> Markdown.generate()

      assert content =~ "## Execution notes\n## summary\ndid the basics"
    end

    test "a verifier cycle feeds Verification", %{project: project} do
      task = task!(project)
      cycle!(task, %{role: "verifier", report: "criterion 1: PASSED"})

      content = task |> reload() |> Markdown.generate()

      assert content =~ "## Verification\ncriterion 1: PASSED"
    end

    test "a reviewer cycle feeds Conformance (outcome) and Review (report)", %{
      project: project
    } do
      task = task!(project)

      cycle!(task, %{
        role: "reviewer",
        outcome: "complies",
        report: "approved without reservations"
      })

      content = task |> reload() |> Markdown.generate()

      assert content =~ "## Conformance\nConformance: complies"
      assert content =~ "## Review\napproved without reservations"
    end

    test "more than one cycle of the same role becomes `### Cycle N`, one per rework", %{
      project: project
    } do
      task = task!(project)
      cycle!(task, %{role: "builder", number: 1, report: "first attempt"})
      cycle!(task, %{role: "builder", number: 2, report: "fixed in rework"})

      content = task |> reload() |> Markdown.generate()

      assert content =~ "### Cycle 1\nfirst attempt"
      assert content =~ "### Cycle 2\nfixed in rework"
    end

    test "a task without cycles leaves the four sections empty", %{project: project} do
      task = task!(project) |> reload()

      content = Markdown.generate(task)

      assert content =~ "## Execution notes\n\n\n## Verification"
      assert content =~ "## Verification\n\n\n## Conformance"
      assert content =~ "## Conformance\n\n\n## Review"
    end
  end

  describe "determinism" do
    test "two generations of the same task produce identical bytes", %{project: project} do
      task = task!(project)
      area!(task, "lib/a.ex")
      criterion!(task, %{text: "single criterion", command: "mix test", level: :executed})
      cycle!(task, %{role: "builder", report: "notes"})

      reloaded = reload(task)

      first = Markdown.generate(reloaded)
      second = Markdown.generate(reload(task))

      assert first == second
      assert :erlang.md5(first) == :erlang.md5(second)
    end

    test "generate/1 does not write to the database (pure function)", %{project: project} do
      task = task!(project) |> reload()
      before = Repo.get!(Task, task.id)

      Markdown.generate(task)

      assert Repo.get!(Task, task.id) == before
    end
  end
end

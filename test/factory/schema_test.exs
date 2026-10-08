defmodule Factory.SchemaTest do
  @moduledoc """
  Locks the schema: what the database accepts, what it rejects and what comes back on read.
  Rules moved into the schema (an invented status, a self-dependency, two active specialists
  with the same identifier) must fail here, not in scattered `if`s.
  """

  use Factory.DataCase, async: true

  alias Factory.Projects.Project
  alias Factory.Projects.Specialist
  alias Factory.Tasks.Area
  alias Factory.Tasks.Criterion
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Dependency
  alias Factory.Tasks.Dispatch
  alias Factory.Tasks.Task
  alias Factory.Tasks.Usage

  defp project!(attrs \\ %{}) do
    default = %{name: "project-#{System.unique_integer([:positive])}", path: "C:/tmp/p"}

    %Project{}
    |> Project.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  defp task!(project, attrs \\ %{}) do
    default = %{
      project_id: project.id,
      code: "T-#{100 + System.unique_integer([:positive])}",
      title: "a task"
    }

    %Task{}
    |> Task.changeset(Map.merge(default, attrs))
    |> Repo.insert!()
  end

  describe "project" do
    test "inserts and reads back, with software as the default domain" do
      project = project!(%{name: "factory", path: "C:/projects/factory"})

      read = Repo.get!(Project, project.id)

      assert read.name == "factory"
      assert read.path == "C:/projects/factory"
      assert read.domain == "software"
      assert read.inserted_at
    end

    test "domain is free text: domains are not a closed list" do
      project = project!(%{domain: "presentation"})
      assert Repo.get!(Project, project.id).domain == "presentation"
    end

    test "a duplicate name is rejected by the database" do
      project!(%{name: "repeated"})

      {:error, changeset} =
        %Project{}
        |> Project.changeset(%{name: "repeated", path: "C:/other"})
        |> Repo.insert()

      assert %{name: ["has already been taken"]} = errors_on(changeset)
    end

    test "name and path are required" do
      changeset = Project.changeset(%Project{}, %{})

      assert %{name: ["can't be blank"], path: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "task" do
    test "inserts with a dependency and an area, and reads everything back" do
      project = project!()
      base = task!(project, %{code: "T-001", title: "scaffold"})
      next = task!(project, %{code: "T-002", title: "schema"})

      Repo.insert!(
        Dependency.changeset(%Dependency{}, %{
          task_id: next.id,
          depends_on_id: base.id
        })
      )

      Repo.insert!(Area.changeset(%Area{}, %{task_id: next.id, path: "priv/repo/migrations"}))

      read = Repo.preload(Repo.get!(Task, next.id), [:areas, dependencies: :depends_on])

      assert read.code == "T-002"
      assert read.status == :backlog
      assert read.priority == :medium
      assert read.attempts == 0
      assert [%Area{path: "priv/repo/migrations"}] = read.areas
      assert [%Dependency{depends_on: %Task{code: "T-001"}}] = read.dependencies
    end

    test "an invalid status is rejected by the changeset" do
      project = project!()

      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          code: "T-009",
          title: "milestone",
          status: :on_vacation
        })

      refute changeset.valid?
      assert %{status: ["is invalid"]} = errors_on(changeset)
    end

    test "accepts the six protocol states and the two terminal ones" do
      project = project!()

      for status <- Task.states() ++ Task.terminal_states() do
        task = task!(project, %{status: status})
        assert Repo.get!(Task, task.id).status == status
      end
    end

    test "a code outside the T-NNN format is rejected" do
      project = project!()

      changeset =
        Task.changeset(%Task{}, %{project_id: project.id, code: "task 1", title: "x"})

      refute changeset.valid?
      assert %{code: [_ | _]} = errors_on(changeset)
    end

    test "a code with a replanning suffix is accepted" do
      project = project!()
      task = task!(project, %{code: "T-017a"})
      assert Repo.get!(Task, task.id).code == "T-017a"
    end

    test "code is citext: the same code in different case is the SAME task" do
      project = project!()
      task!(project, %{code: "T-042"})

      {:error, changeset} =
        %Task{}
        |> Task.changeset(%{project_id: project.id, code: "t-042", title: "another"})
        |> Repo.insert()

      assert %{project_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "the same code coexists in different projects" do
      one = task!(project!(), %{code: "T-001"})
      other = task!(project!(), %{code: "T-001"})

      assert one.id != other.id
    end

    test "negative attempts are rejected" do
      project = project!()

      changeset =
        Task.changeset(%Task{}, %{
          project_id: project.id,
          code: "T-003",
          title: "x",
          attempts: -1
        })

      refute changeset.valid?
      assert %{attempts: [_ | _]} = errors_on(changeset)
    end

    test "a replanned task points to the original" do
      project = project!()
      original = task!(project, %{code: "T-017", status: :cancelled})
      replacement = task!(project, %{code: "T-017a", replanned_from_id: original.id})

      read = Repo.preload(Repo.get!(Task, replacement.id), :replanned_from)
      assert read.replanned_from.code == "T-017"
    end
  end

  describe "dependencies" do
    test "a self-dependency is rejected by the DATABASE, with a named message" do
      task = task!(project!())

      # The changeset is valid; only the database CHECK rejects it, translated by
      # `check_constraint`. Dropping the constraint from the migration breaks this test.
      changeset =
        Dependency.changeset(%Dependency{}, %{
          task_id: task.id,
          depends_on_id: task.id
        })

      assert changeset.valid?

      {:error, rejected} = Repo.insert(changeset)

      assert %{depends_on_id: ["a task cannot depend on itself"]} = errors_on(rejected)
    end

    test "the same edge twice is rejected" do
      project = project!()
      one = task!(project)
      other = task!(project)
      attrs = %{task_id: one.id, depends_on_id: other.id}

      Repo.insert!(Dependency.changeset(%Dependency{}, attrs))

      {:error, changeset} =
        %Dependency{} |> Dependency.changeset(attrs) |> Repo.insert()

      refute changeset.valid?
    end
  end

  describe "areas" do
    test "the same file twice in the same task is rejected" do
      task = task!(project!())
      attrs = %{task_id: task.id, path: "mix.exs"}

      Repo.insert!(Area.changeset(%Area{}, attrs))

      {:error, changeset} = %Area{} |> Area.changeset(attrs) |> Repo.insert()
      assert %{task_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "criteria" do
    test "an executed criterion stores its command" do
      task = task!(project!())

      criterion =
        Repo.insert!(
          Criterion.changeset(%Criterion{}, %{
            task_id: task.id,
            text: "the suite passes",
            command: "mix verify",
            level: :executed
          })
        )

      assert Repo.get!(Criterion, criterion.id).level == :executed
    end

    test "an executed criterion WITHOUT a command is rejected" do
      task = task!(project!())

      changeset =
        Criterion.changeset(%Criterion{}, %{
          task_id: task.id,
          text: "runs",
          level: :executed
        })

      assert %{command: ["an executed criterion needs a command"]} = errors_on(changeset)
    end

    test "a criterion with a command but a weaker level is rejected" do
      task = task!(project!())

      changeset =
        Criterion.changeset(%Criterion{}, %{
          task_id: task.id,
          text: "runs",
          command: "mix test",
          level: :judged
        })

      assert %{level: ["a criterion with a command must have level :executed"]} =
               errors_on(changeset)
    end

    test "an invalid level is rejected" do
      task = task!(project!())

      changeset =
        Criterion.changeset(%Criterion{}, %{task_id: task.id, text: "x", level: :hunch})

      assert %{level: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "versioned specialists" do
    test "two active rows with the same identifier are rejected" do
      project = project!()

      attrs = %{
        project_id: project.id,
        identifier: "frontend",
        name: "Front",
        prompt: "v1"
      }

      Repo.insert!(Specialist.changeset(%Specialist{}, attrs))

      {:error, changeset} =
        %Specialist{} |> Specialist.changeset(attrs) |> Repo.insert()

      assert %{project_id: [_ | _]} = errors_on(changeset)
    end

    test "changing the prompt creates a new row and keeps the history queryable" do
      project = project!()

      base = %{project_id: project.id, identifier: "frontend", name: "Front"}

      old =
        Repo.insert!(Specialist.changeset(%Specialist{}, Map.put(base, :prompt, "v1")))

      Repo.update!(Specialist.changeset(old, %{active: false}))
      Repo.insert!(Specialist.changeset(%Specialist{}, Map.put(base, :prompt, "v2")))

      all =
        Specialist
        |> Repo.all()
        |> Enum.filter(&(&1.project_id == project.id))

      assert length(all) == 2
      assert Enum.count(all, & &1.active) == 1
      assert Enum.find(all, & &1.active).prompt == "v2"
    end
  end

  describe "cycles, dispatches and usages" do
    test "one cycle per rework, and per-turn usage sums to the total" do
      task = task!(project!())

      cycle =
        Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "builder"}))

      dispatch =
        Repo.insert!(
          Dispatch.changeset(%Dispatch{}, %{
            cycle_id: cycle.id,
            provider: "Provider.Fake",
            model: "haiku-4.5",
            turns: 2
          })
        )

      for turn <- 1..2 do
        Repo.insert!(
          Usage.changeset(%Usage{}, %{
            dispatch_id: dispatch.id,
            turn: turn,
            input_tokens: 100 * turn,
            cache_read_tokens: 900 * turn,
            output_tokens: 10 * turn
          })
        )
      end

      read = Repo.preload(Repo.get!(Dispatch, dispatch.id), :usages)

      assert length(read.usages) == 2
      assert Enum.sum(Enum.map(read.usages, & &1.input_tokens)) == 300
      assert Enum.sum(Enum.map(read.usages, & &1.cache_read_tokens)) == 2700
    end

    test "the same turn twice in the same dispatch is rejected" do
      task = task!(project!())

      cycle =
        Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "verifier"}))

      dispatch =
        Repo.insert!(
          Dispatch.changeset(%Dispatch{}, %{
            cycle_id: cycle.id,
            provider: "Provider.Fake",
            model: "haiku-4.5"
          })
        )

      attrs = %{dispatch_id: dispatch.id, turn: 1}
      Repo.insert!(Usage.changeset(%Usage{}, attrs))

      {:error, changeset} = %Usage{} |> Usage.changeset(attrs) |> Repo.insert()
      assert %{dispatch_id: ["has already been taken"]} = errors_on(changeset)
    end

    test "turn zero is rejected: counting starts at 1" do
      task = task!(project!())

      cycle =
        Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "r"}))

      dispatch =
        Repo.insert!(
          Dispatch.changeset(%Dispatch{}, %{cycle_id: cycle.id, provider: "o", model: "m"})
        )

      changeset = Usage.changeset(%Usage{}, %{dispatch_id: dispatch.id, turn: 0})

      refute changeset.valid?
      assert %{turn: [_ | _]} = errors_on(changeset)
    end

    test "negative tokens are rejected" do
      task = task!(project!())

      cycle =
        Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "r"}))

      dispatch =
        Repo.insert!(
          Dispatch.changeset(%Dispatch{}, %{cycle_id: cycle.id, provider: "o", model: "m"})
        )

      changeset =
        Usage.changeset(%Usage{}, %{
          dispatch_id: dispatch.id,
          turn: 1,
          cache_write_tokens: -5
        })

      refute changeset.valid?
      assert %{cache_write_tokens: [_ | _]} = errors_on(changeset)
    end

    test "deleting the task takes cycles, dispatches and usages with it" do
      task = task!(project!())

      cycle =
        Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "c"}))

      dispatch =
        Repo.insert!(
          Dispatch.changeset(%Dispatch{}, %{cycle_id: cycle.id, provider: "o", model: "m"})
        )

      Repo.insert!(Usage.changeset(%Usage{}, %{dispatch_id: dispatch.id, turn: 1}))

      Repo.delete!(task)

      refute Repo.get(Cycle, cycle.id)
      refute Repo.get(Dispatch, dispatch.id)
      assert Repo.aggregate(Usage, :count) == 0
    end
  end
end

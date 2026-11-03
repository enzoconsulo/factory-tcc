defmodule Factory.Team.ResolutionTest do
  @moduledoc """
  The on-demand team: versioning, resolution and the dispatch block. `Resolution` is pure and
  tested with plain structs; `Team` touches the database, where the partial unique index proves
  the versioning.
  """

  use Factory.DataCase, async: true

  alias Factory.Projects.Project
  alias Factory.Projects.Specialist
  alias Factory.Tasks.Task
  alias Factory.Team
  alias Factory.Team.Resolution

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

  # Silences the expected unknown-specialist warning; a dedicated test checks it.
  defp capturing(fun) do
    {result, _log} = ExUnit.CaptureLog.with_log(fun)
    result
  end

  defp specialist(identifier, prompt \\ "domain prompt") do
    %Specialist{
      id: System.unique_integer([:positive]),
      identifier: identifier,
      name: "the #{identifier}",
      prompt: prompt,
      active: true
    }
  end

  describe "resolution — the specialist ADDS, never replaces" do
    test "without a reference it runs on the generic role, which is normal" do
      assert %Resolution{role: :builder, specialist: nil, reason: :generic} =
               Resolution.resolve(:builder, nil, [specialist("frontend")])
    end

    test "with an existing reference it returns the specialist" do
      active = [specialist("frontend"), specialist("database")]

      assert %Resolution{reason: :specialist, specialist: %{identifier: "database"}} =
               Resolution.resolve(:builder, "database", active)
    end

    test "the role is always in the result, even with a specialist" do
      for role <- [:builder, :verifier, :reviewer] do
        assert %Resolution{role: ^role} =
                 Resolution.resolve(role, "frontend", [specialist("frontend")])
      end
    end
  end

  describe "resolution — an unknown specialist falls back to generic AND is recorded" do
    test "a reference not among the active ones" do
      resolution =
        capturing(fn ->
          Resolution.resolve(:builder, "ghost", [specialist("frontend")])
        end)

      assert resolution.specialist == nil
      assert resolution.role == :builder
      assert resolution.reason == {:unknown_specialist, {:identifier, "ghost"}}
      assert Resolution.defective?(resolution)
    end

    test "the defect GOES TO THE LOG, not only to the return value" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Resolution.resolve(:builder, "ghost", [])
        end)

      assert log =~ "unknown specialist"
      assert log =~ "ghost"
      assert log =~ "planning defect"
    end

    test "a SUCCESSFUL resolution does not pollute the log" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Resolution.resolve(:builder, "frontend", [specialist("frontend")])
          Resolution.resolve(:builder, nil, [])
        end)

      refute log =~ "unknown specialist"
    end

    test "an empty active list" do
      resolution = capturing(fn -> Resolution.resolve(:builder, "frontend", []) end)

      assert {:unknown_specialist, _} = resolution.reason
    end

    test "an INACTIVE specialist does not resolve" do
      inactive = %{specialist("frontend") | active: false}

      assert %Resolution{reason: {:unknown_specialist, _}} =
               capturing(fn -> Resolution.resolve(:builder, "frontend", [inactive]) end)
    end

    test "a resolution without a defect is not marked defective" do
      refute Resolution.defective?(Resolution.resolve(:builder, nil, []))

      refute Resolution.defective?(
               Resolution.resolve(:builder, "frontend", [specialist("frontend")])
             )
    end
  end

  describe "the assembled doctrine — its own block beside the role" do
    test "without a specialist, only the role block" do
      text =
        :builder
        |> Resolution.resolve(nil, [])
        |> Resolution.doctrine("you implement a task end to end")

      assert text == "<your-role>\nyou implement a task end to end\n</your-role>"
      refute text =~ "<specialist>"
    end

    test "with a specialist, BOTH blocks, in this order" do
      text =
        :builder
        |> Resolution.resolve("database", [
          specialist("database", "migrations live in priv/repo")
        ])
        |> Resolution.doctrine("you implement a task")

      assert text =~ "<your-role>"
      assert text =~ "<specialist>"
      assert text =~ "You act as the database on this team."
      assert text =~ "migrations live in priv/repo"

      position = fn tag -> :binary.match(text, tag) |> elem(0) end
      assert position.("<your-role>") < position.("<specialist>")
    end

    test "both blocks are closed" do
      text =
        :builder
        |> Resolution.resolve("database", [specialist("database")])
        |> Resolution.doctrine("role")

      assert text =~ "</your-role>"
      assert text =~ "</specialist>"
    end

    test "an unknown specialist produces ONLY the role block" do
      text =
        capturing(fn ->
          :builder
          |> Resolution.resolve("ghost", [])
          |> Resolution.doctrine("role")
        end)

      refute text =~ "<specialist>"
    end
  end

  describe "versioning — changing the prompt creates a new row" do
    test "the second version goes in and the first becomes inactive", %{project: project} do
      {:ok, first} =
        Team.define(project.id, %{
          identifier: "database",
          name: "the database one",
          prompt: "first wording"
        })

      {:ok, second} =
        Team.define(project.id, %{
          identifier: "database",
          name: "the database one",
          prompt: "second wording"
        })

      assert second.id != first.id
      assert second.active
      refute Repo.get!(Specialist, first.id).active
    end

    test "the history is queryable, newest first", %{project: project} do
      for wording <- ["first", "second", "third"] do
        {:ok, _} =
          Team.define(project.id, %{identifier: "database", name: "b", prompt: wording})
      end

      prompts = project.id |> Team.history("database") |> Enum.map(& &1.prompt)

      assert prompts == ["third", "second", "first"]
    end

    test "only ONE version stays active, guaranteed by the database", %{project: project} do
      for wording <- ["a", "b", "c"] do
        {:ok, _} =
          Team.define(project.id, %{identifier: "database", name: "b", prompt: wording})
      end

      active =
        Repo.all(
          from(s in Specialist,
            where: s.project_id == ^project.id and s.identifier == "database" and s.active
          )
        )

      assert length(active) == 1

      # The rule belongs to the SCHEMA: inserting a second active row directly is refused.
      assert {:error, changeset} =
               %Specialist{}
               |> Specialist.changeset(%{
                 project_id: project.id,
                 identifier: "database",
                 name: "b",
                 prompt: "from outside"
               })
               |> Repo.insert()

      # `unique_constraint/2` with a list reports on its FIRST field.
      assert %{project_id: [message]} = errors_on(changeset)
      assert message =~ "an active specialist with this identifier already exists"
    end

    test "different specialists do not deactivate each other", %{project: project} do
      {:ok, _} = Team.define(project.id, %{identifier: "database", name: "b", prompt: "x"})
      {:ok, _} = Team.define(project.id, %{identifier: "frontend", name: "f", prompt: "y"})
      {:ok, _} = Team.define(project.id, %{identifier: "database", name: "b", prompt: "z"})

      identifiers = project.id |> Team.list_active() |> Enum.map(& &1.identifier)
      assert identifiers == ["database", "frontend"]
    end

    test "missing required fields return an error and nothing is deactivated", %{
      project: project
    } do
      {:ok, original} =
        Team.define(project.id, %{identifier: "database", name: "b", prompt: "x"})

      assert {:error, %Ecto.Changeset{}} =
               Team.define(project.id, %{identifier: "database", name: "b"})

      # Deactivation and insertion are the SAME transaction.
      assert Repo.get!(Specialist, original.id).active
    end
  end

  describe "Team.resolve — from the task's reference to the active version" do
    test "a task without a specialist runs on the generic role", %{project: project} do
      task = task!(project, %{})

      assert %Resolution{reason: :generic} = Team.resolve(task, :builder)
    end

    test "resolves to the ACTIVE version, not the one referenced", %{project: project} do
      {:ok, old} =
        Team.define(project.id, %{identifier: "database", name: "b", prompt: "old wording"})

      {:ok, new} =
        Team.define(project.id, %{identifier: "database", name: "b", prompt: "new wording"})

      task = task!(project, %{specialist_id: old.id})

      assert %Resolution{specialist: resolved, reason: :specialist} =
               Team.resolve(task, :builder)

      assert resolved.id == new.id
      assert resolved.prompt == "new wording"
    end

    test "a reference to a missing row falls back to generic AND is recorded", %{
      project: project
    } do
      task = task!(project, %{})
      orphan = %{task | specialist_id: 999_999}

      resolution = capturing(fn -> Team.resolve(orphan, :builder) end)

      assert resolution.specialist == nil
      assert resolution.reason == {:unknown_specialist, {:id, 999_999}}
      assert Resolution.defective?(resolution)
    end

    test "a specialist from ANOTHER project does not serve this task", %{project: project} do
      other =
        %Project{}
        |> Project.changeset(%{
          name: "other-#{System.unique_integer([:positive])}",
          path: "C:/o"
        })
        |> Repo.insert!()

      {:ok, foreign} =
        Team.define(other.id, %{identifier: "database", name: "b", prompt: "from the other"})

      task = task!(project, %{})
      pointing = %{task | specialist_id: foreign.id}

      assert %Resolution{reason: {:unknown_specialist, {:identifier, "database"}}} =
               capturing(fn -> Team.resolve(pointing, :builder) end)
    end
  end
end

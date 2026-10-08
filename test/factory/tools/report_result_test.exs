defmodule Factory.Tools.ReportResultTest do
  @moduledoc """
  The only way an agent reports, and the IMPOSSIBILITY of it changing state. The key test is
  negative: it scans every role's tools and fails if any can write status or attempts.
  """

  use Factory.DataCase, async: true

  alias Factory.Projects.Project
  alias Factory.Tasks.Cycle
  alias Factory.Tasks.Task
  alias Factory.Tools.Catalog
  alias Factory.Tools.ReportResult

  defp cycle! do
    project =
      Repo.insert!(
        Project.changeset(%Project{}, %{
          name: "p-#{System.unique_integer([:positive])}",
          path: "C:/tmp/p"
        })
      )

    task =
      Repo.insert!(
        Task.changeset(%Task{}, %{
          project_id: project.id,
          code: "T-#{100 + System.unique_integer([:positive])}",
          title: "report"
        })
      )

    Repo.insert!(Cycle.changeset(%Cycle{}, %{task_id: task.id, number: 1, role: "builder"}))
  end

  describe "recording the report" do
    test "stores it on the current cycle, inside a transaction" do
      cycle = cycle!()

      assert {:ok, %{recorded: true, warnings: []}} =
               ReportResult.record(cycle.id, %{
                 summary: "created the module and the test",
                 files: ["lib/x.ex", "test/x_test.exs"],
                 commands: ["mix verify"],
                 commit: "abc1234"
               })

      stored = Repo.get!(Cycle, cycle.id)

      assert stored.report =~ "created the module and the test"
      assert stored.report =~ "lib/x.ex"
      assert stored.report =~ "mix verify"
      assert stored.report =~ "abc1234"
    end

    test "accepts a declared blocker" do
      cycle = cycle!()

      assert {:ok, %{recorded: true}} =
               ReportResult.record(cycle.id, %{
                 summary: "could not do it",
                 blocker: "the criterion requires a binary that does not exist on this machine"
               })

      assert Repo.get!(Cycle, cycle.id).report =~ "binary that does not exist"
    end

    test "a missing cycle returns a named error and stores nothing" do
      assert {:error, {:cycle_missing, 999_999}} =
               ReportResult.record(999_999, %{summary: "x"})
    end

    test "sections come out in a stable order" do
      # The report becomes committed markdown; an unstable order would create spurious diffs.
      cycle = cycle!()

      ReportResult.record(cycle.id, %{commit: "abc", summary: "r", files: ["a"]})
      first = Repo.get!(Cycle, cycle.id).report

      other = cycle!()
      ReportResult.record(other.id, %{files: ["a"], summary: "r", commit: "abc"})
      second = Repo.get!(Cycle, other.id).report

      assert first == second
    end
  end

  describe "SYSTEM fields are ignored, with a warning" do
    test "status sent by the agent is ignored" do
      cycle = cycle!()

      assert {:ok, %{warnings: [warning]}} =
               ReportResult.record(cycle.id, %{summary: "did it", status: "done"})

      assert warning =~ "status"
      assert warning =~ "IGNORED"
      refute Repo.get!(Cycle, cycle.id).report =~ "done"
    end

    test "attempts sent by the agent is ignored" do
      cycle = cycle!()

      assert {:ok, %{warnings: [warning]}} =
               ReportResult.record(cycle.id, %{summary: "did it", attempts: 0})

      assert warning =~ "attempts"
    end

    test "the warning EXPLAINS who owns the field, not only that it was refused" do
      {_, [warning]} = ReportResult.split(%{status: "done"})

      assert warning =~ "belongs to the system"
      assert warning =~ "the state follows from it"
    end

    test "several system fields produce one warning each, in stable order" do
      {accepted, warnings} =
        ReportResult.split(%{summary: "r", status: "x", attempts: 2, outcome: "ok"})

      assert accepted == %{summary: "r"}
      assert length(warnings) == 3
      assert warnings == Enum.sort(warnings) |> Enum.sort()
    end

    test "the warning comes back in the same response, never silently" do
      cycle = cycle!()

      {:ok, reply} = ReportResult.record(cycle.id, %{summary: "r", status: "x"})

      assert reply.recorded
      refute reply.warnings == []
    end

    test "an unknown field is simply ignored, without a warning" do
      # Only fields known to belong to the system produce warnings; warning on everything
      # would be noise.
      {accepted, warnings} = ReportResult.split(%{summary: "r", invented_by_the_agent: 1})

      assert accepted == %{summary: "r"}
      assert warnings == []
    end

    test "string keys work like atom keys" do
      {accepted, warnings} = ReportResult.split(%{"summary" => "r", "status" => "x"})

      assert accepted == %{summary: "r"}
      assert length(warnings) == 1
    end

    test "an invented string key does not exhaust the atom table" do
      {accepted, warnings} = ReportResult.split(%{"never_seen_#{:rand.uniform(9)}" => 1})

      assert accepted == %{}
      assert warnings == []
    end
  end

  describe "NEGATIVE TEST: no tool of any role writes state" do
    test "no role has a tool with the power to write state" do
      for role <- Catalog.roles() do
        {:ok, tools} = Catalog.for_role(role)

        for {name, tool} <- tools do
          refute tool.power == :state,
                 "role #{role} has tool #{name} with the power to write STATE"
        end
      end
    end

    test "the :state power does not exist in the whole catalog" do
      refute :state in Catalog.powers()
    end

    test "no tool is named like a state change" do
      forbidden = ~w[change_status set_status complete approve reject increment_attempts]

      for {name, _} <- Catalog.tools(), f <- forbidden do
        refute name == f, "tool #{name} must not exist: state belongs to the system"
      end
    end

    test "no tool module even REACHES the Task schema" do
      # A tool module that never references `Factory.Tasks.Task` cannot write status or
      # attempts, whatever its documentation says. The report goes to `Cycle`.
      for file <- Path.wildcard("lib/factory/tools/**/*.ex") do
        code =
          file
          |> File.read!()
          |> String.replace(
            ~r/"""
.*?"""/s,
            ""
          )
          |> String.replace(~r/^\s*#.*$/m, "")

        refute code =~ "Tasks.Task",
               "#{file} reaches the Task schema. No tool may: state belongs to the " <>
                 "system, and the agent report goes to Cycle."
      end
    end

    test "the detector above works and does not pass vacuously" do
      code = ~s(defmodule X do\n  alias Factory.Tasks.Task\nend)
      prose_only = ~s(defmodule X do\n  @moduledoc """\n  talks about Tasks.Task\n  """\nend)

      strip = fn text ->
        text
        |> String.replace(
          ~r/"""
.*?"""/s,
          ""
        )
        |> String.replace(~r/^\s*#.*$/m, "")
      end

      assert strip.(code) =~ "Tasks.Task"
      refute strip.(prose_only) =~ "Tasks.Task"
    end

    test "verifier and reviewer do NOT get a write tool" do
      refute Catalog.can_write?("verifier")
      refute Catalog.can_write?("reviewer")
    end

    test "the builder DOES get a write tool" do
      # The counter-proof: otherwise `can_write?` could always return false.
      assert Catalog.can_write?("builder")
      assert Catalog.can_write?("documenter")
    end

    test "every role gets report_result" do
      for role <- Catalog.roles() do
        {:ok, tools} = Catalog.for_role(role)
        assert Map.has_key?(tools, "report_result"), "#{role} cannot report"
      end
    end

    test "an unknown role returns an error, not an empty list" do
      assert {:error, :unknown_role} = Catalog.for_role("invented")
    end
  end
end

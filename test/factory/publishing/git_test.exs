defmodule Factory.Publishing.GitTest do
  @moduledoc """
  No write outside the `areas` disappears silently, and no commit uses `add -A`.
  """

  use ExUnit.Case, async: true

  alias Factory.Publishing.Git
  alias Factory.Tools.Command

  @moduletag :capture_log

  setup do
    root =
      Path.join([
        File.cwd!(),
        "_build",
        "test",
        "tmp",
        "git-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(root)
    {:ok, _} = git(root, ["init"])
    {:ok, _} = git(root, ["config", "user.email", "factory@test.local"])
    {:ok, _} = git(root, ["config", "user.name", "Test Factory"])

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp git(root, args), do: Command.run(root, "git", args)

  defp write(root, path, content) do
    absolute = Path.join(root, path)
    File.mkdir_p!(Path.dirname(absolute))
    File.write!(absolute, content)
  end

  defp log(root) do
    {:ok, %{stdout: output}} = git(root, ["log", "-1", "--pretty=%s"])
    String.trim(output)
  end

  describe "message/2" do
    test "builds the canonical message T-NNN: title" do
      assert Git.message("T-032", "Markdown generation") == "T-032: Markdown generation"
    end
  end

  describe "changes_outside/2" do
    test "empty when only the declared areas changed", %{root: root} do
      write(root, "lib/a.ex", "content a")
      write(root, "_management/tasks/T-001-x.md", "task")

      assert {:ok, []} =
               Git.changes_outside(root, ["lib/a.ex", "_management/tasks/T-001-x.md"])
    end

    test "points out the path that changed outside the areas", %{root: root} do
      write(root, "lib/a.ex", "declared")
      write(root, "lib/b.ex", "NOT declared")

      assert {:ok, ["lib/b.ex"]} = Git.changes_outside(root, ["lib/a.ex"])
    end

    test "an UNTRACKED file outside the areas also counts", %{root: root} do
      write(root, "lib/a.ex", "v1")
      {:ok, _} = git(root, ["add", "--", "lib/a.ex"])
      {:ok, _} = git(root, ["commit", "-m", "base"])

      write(root, "lib/a.ex", "v2 declared")
      write(root, "lib/stray.ex", "written by mistake, outside the area")

      assert {:ok, ["lib/stray.ex"]} = Git.changes_outside(root, ["lib/a.ex"])
    end
  end

  describe "commit/3" do
    test "commits the areas plus the task file, with the message T-NNN: title", %{
      root: root
    } do
      write(root, "lib/a.ex", "code")
      write(root, "_management/tasks/T-050-something.md", "task")

      paths = ["lib/a.ex", "_management/tasks/T-050-something.md"]
      message = Git.message("T-050", "Task title")

      assert {:ok, _} = Git.commit(root, paths, message)
      assert log(root) == message

      assert {:ok, %{code: 0, stdout: status}} = git(root, ["status", "--porcelain"])
      assert String.trim(status) == ""
    end

    test "refuses and REPORTS changes outside the areas, committing nothing", %{
      root: root
    } do
      write(root, "lib/a.ex", "declared")
      write(root, "lib/outside.ex", "outside the area, by mistake")

      assert {:error, {:changes_outside_areas, ["lib/outside.ex"]}} =
               Git.commit(root, ["lib/a.ex"], "T-050: title")

      assert {:ok, %{code: 128}} = git(root, ["rev-parse", "HEAD"])

      assert {:ok, %{code: 0, stdout: status}} =
               git(root, ["status", "--porcelain", "--untracked-files=all"])

      assert status =~ "lib/a.ex"
      assert status =~ "lib/outside.ex"
    end

    test "never `git add -A`: a file outside the areas stays out even when the commit passes",
         %{root: root} do
      write(root, "lib/a.ex", "declared")
      {:ok, _} = Git.commit(root, ["lib/a.ex"], "T-050: first commit")

      write(root, "lib/a.ex", "declared again")
      write(root, "lib/undeclared.ex", "should never go along")

      assert {:error, {:changes_outside_areas, ["lib/undeclared.ex"]}} =
               Git.commit(root, ["lib/a.ex"], "T-050: second commit")

      assert log(root) == "T-050: first commit"
    end
  end

  describe "hash/1" do
    test "returns the short hash of the latest commit", %{root: root} do
      write(root, "lib/a.ex", "code")
      {:ok, _} = Git.commit(root, ["lib/a.ex"], "T-050: title")

      assert {:ok, hash} = Git.hash(root)
      assert String.match?(hash, ~r/^[0-9a-f]{7,}$/)
    end
  end
end

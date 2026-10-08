defmodule Factory.BackupTest do
  @moduledoc """
  Exercises the backup cycle AGAINST THE REAL DATABASE.

  `async: false` because restoring runs `pg_restore --clean --if-exists`, which drops and
  recreates the test database's tables. Writes that `pg_dump` must see run in
  `unboxed_run`: the sandbox keeps everything in an uncommitted transaction that the external
  `pg_dump` process would not see, and the round trip would prove nothing.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Factory.Backup
  alias Factory.Projects.Project
  alias Factory.Repo
  alias Factory.Tasks.Task

  @moduletag :needs_pg_dump

  setup do
    dest = Path.join(System.tmp_dir!(), "factory-#{System.unique_integer([:positive])}.dump")

    on_exit(fn ->
      File.rm(dest)
      Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(Project) end)
    end)

    {:ok, dest: dest}
  end

  defp seed(name, code) do
    Sandbox.unboxed_run(Repo, fn ->
      project =
        Repo.insert!(Project.changeset(%Project{}, %{name: name, path: "C:/tmp/#{name}"}))

      Repo.insert!(
        Task.changeset(%Task{}, %{
          project_id: project.id,
          code: code,
          title: "survive the dump",
          status: :in_testing,
          attempts: 2
        })
      )
    end)
  end

  defp fetch(code) do
    Sandbox.unboxed_run(Repo, fn -> Repo.get_by(Task, code: code) end)
  end

  # `pg_restore --clean` recreates `citext` with a new oid, and live connections keep the
  # old one cached. `Factory.Backup` drops connections in dev and prod, but the sandbox pool
  # does not support it, so the Repo is restarted here by hand.
  defp restore(dest) do
    # The warning is captured, not silenced: under the sandbox the restore must warn that
    # connections could not be dropped.
    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Backup.restore(dest)
      end)

    assert log =~ "connections were NOT dropped",
           "under the sandbox the restore MUST warn; without it, a production restore " <>
             "would leave the application running and broken without anyone knowing"

    Supervisor.terminate_child(Factory.Supervisor, Factory.Repo)
    Supervisor.restart_child(Factory.Supervisor, Factory.Repo)
    Sandbox.mode(Repo, :manual)

    result
  end

  defp delete_all do
    Sandbox.unboxed_run(Repo, fn -> Repo.delete_all(Project) end)
  end

  describe "dump" do
    test "writes a dump file and returns its path", %{dest: dest} do
      seed("project-dump", "T-100")

      assert {:ok, ^dest} = Backup.dump(dest: dest)
      assert File.exists?(dest)
      assert File.stat!(dest).size > 0
    end

    test "creates the destination directory if missing" do
      path =
        System.tmp_dir!()
        |> Path.join("factory-new-#{System.unique_integer([:positive])}")
        |> Path.join("inside/of/nothing.dump")

      on_exit(fn -> File.rm_rf(Path.dirname(Path.dirname(path))) end)

      assert {:ok, _} = Backup.dump(dest: path)
      assert File.exists?(path)
    end

    test "without a destination, the name carries a date-time stamp" do
      # A timestamped name keeps a backup from overwriting the previous one.
      {:ok, path} = Backup.dump()
      on_exit(fn -> File.rm(path) end)

      assert Path.basename(path) =~ ~r/^\d{8}-\d{6}\.dump$/
      assert Path.dirname(path) == Backup.directory()
    end
  end

  describe "the full cycle: backup -> delete -> restore" do
    test "brings back the same data", %{dest: dest} do
      seed("project-cycle", "T-200")

      before = fetch("T-200")
      assert before.title == "survive the dump"
      assert before.status == :in_testing
      assert before.attempts == 2

      assert {:ok, ^dest} = Backup.dump(dest: dest)

      delete_all()
      refute fetch("T-200"), "the task must REALLY disappear, or the round trip proves nothing"

      assert {:ok, ^dest} = restore(dest)

      after_restore = fetch("T-200")
      assert after_restore, "the task had to come back"
      assert after_restore.code == "T-200"
      assert after_restore.title == "survive the dump"
      assert after_restore.status == :in_testing
      assert after_restore.attempts == 2
    end

    test "restoring twice in a row works (--clean --if-exists)", %{dest: dest} do
      seed("project-repeated", "T-201")
      {:ok, _} = Backup.dump(dest: dest)

      assert {:ok, _} = restore(dest)
      assert {:ok, _} = restore(dest)

      assert fetch("T-201")
    end
  end

  describe "errors" do
    test "restoring a missing dump returns a named error" do
      assert {:error, {:dump_missing, "does/not/exist.dump"}} =
               Backup.restore("does/not/exist.dump")
    end

    test "a missing executable returns a named error, not a raw exception" do
      original = Application.get_env(:factory, :pg_bin)
      Application.put_env(:factory, :pg_bin, "C:/path/that/does/not/exist")
      on_exit(fn -> Application.put_env(:factory, :pg_bin, original) end)

      assert {:error, {:executable_missing, _, _}} = Backup.dump(dest: "x.dump")
      refute Backup.available?()
    end
  end

  describe "listing" do
    test "lists dumps newest first" do
      dir = Path.join(System.tmp_dir!(), "dumps-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      original = Application.get_env(:factory, :backup_dir)
      Application.put_env(:factory, :backup_dir, dir)

      on_exit(fn ->
        # `delete_env` when there was no key: `put_env(nil)` would leave the key present.
        if original,
          do: Application.put_env(:factory, :backup_dir, original),
          else: Application.delete_env(:factory, :backup_dir)

        File.rm_rf(dir)
      end)

      for name <- ["20260101-000000.dump", "20260828-120000.dump", "20260501-000000.dump"] do
        File.write!(Path.join(dir, name), "x")
      end

      File.write!(Path.join(dir, "readme.txt"), "not a dump")

      assert Backup.list() |> Enum.map(&Path.basename/1) == [
               "20260828-120000.dump",
               "20260501-000000.dump",
               "20260101-000000.dump"
             ]
    end

    test "a missing directory lists empty without crashing" do
      original = Application.get_env(:factory, :backup_dir)
      Application.put_env(:factory, :backup_dir, "does/not/exist")

      on_exit(fn ->
        if original,
          do: Application.put_env(:factory, :backup_dir, original),
          else: Application.delete_env(:factory, :backup_dir)
      end)

      assert Backup.list() == []
    end
  end

  describe "configuration" do
    test "the executable comes from config, never from the PATH" do
      original = Application.get_env(:factory, :pg_bin)
      Application.put_env(:factory, :pg_bin, "C:/pgsql/18/bin")
      on_exit(fn -> Application.put_env(:factory, :pg_bin, original) end)

      assert Backup.executable("pg_dump") == "C:/pgsql/18/bin/pg_dump"
    end

    test "without config, falls back to the bare name" do
      original = Application.get_env(:factory, :pg_bin)
      Application.delete_env(:factory, :pg_bin)
      on_exit(fn -> Application.put_env(:factory, :pg_bin, original) end)

      assert Backup.executable("pg_dump") == "pg_dump"
    end
  end
end

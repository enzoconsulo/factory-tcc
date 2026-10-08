defmodule Factory.Tools.FilesTest do
  @moduledoc """
  The file tools, with special attention to `edit`: refusing zero or multiple occurrences
  prevents an edit that "almost" matches from silently corrupting the file.
  """

  use ExUnit.Case, async: true

  alias Factory.Tools.Files

  setup do
    root = Path.join(System.tmp_dir!(), "files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib"))
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp create(root, path, content) do
    full = Path.join(root, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, content)
  end

  describe "read" do
    test "reads a project file", %{root: root} do
      create(root, "lib/x.ex", "content")
      assert {:ok, "content"} = Files.read(root, "lib/x.ex")
    end

    test "a missing file returns a named error", %{root: root} do
      assert {:error, :file_missing} = Files.read(root, "does/not/exist.ex")
    end

    test "a directory is not a file", %{root: root} do
      assert {:error, :not_a_file} = Files.read(root, "lib")
    end

    test "a file that is too large is refused, not read halfway", %{root: root} do
      create(root, "huge.txt", String.duplicate("x", 2_000_001))
      assert {:error, :file_too_large} = Files.read(root, "huge.txt")
    end
  end

  describe "write" do
    test "writes and creates missing directories", %{root: root} do
      assert {:ok, _} = Files.write(root, "new/deep/x.ex", "hi")
      assert {:ok, "hi"} = Files.read(root, "new/deep/x.ex")
    end

    test "overwrites an existing file", %{root: root} do
      create(root, "x.ex", "old")
      assert {:ok, _} = Files.write(root, "x.ex", "new")
      assert {:ok, "new"} = Files.read(root, "x.ex")
    end
  end

  describe "edit — EXACT replacement" do
    test "replaces a single occurrence", %{root: root} do
      create(root, "x.ex", "before the target after")

      assert {:ok, _} = Files.edit(root, "x.ex", "target", "replaced")
      assert {:ok, "before the replaced after"} = Files.read(root, "x.ex")
    end

    test "refuses when the target appears ZERO times", %{root: root} do
      create(root, "x.ex", "any content")

      assert {:error, :target_missing} = Files.edit(root, "x.ex", "not here", "new")
    end

    test "zero occurrences do NOT change the file", %{root: root} do
      create(root, "x.ex", "original")
      Files.edit(root, "x.ex", "missing", "new")

      assert {:ok, "original"} = Files.read(root, "x.ex")
    end

    test "refuses when the target appears MORE THAN ONCE", %{root: root} do
      create(root, "x.ex", "repeat repeat")

      assert {:error, :target_ambiguous} = Files.edit(root, "x.ex", "repeat", "replaced")
    end

    test "an ambiguous target does NOT change the file", %{root: root} do
      create(root, "x.ex", "def add\ndef add")
      Files.edit(root, "x.ex", "def add", "def subtract")

      assert {:ok, "def add\ndef add"} = Files.read(root, "x.ex")
    end

    test "counts occurrences that overlap in the text", %{root: root} do
      create(root, "x.ex", "aaa")
      assert {:error, :target_ambiguous} = Files.edit(root, "x.ex", "a", "b")
    end

    test "a multi-line target works", %{root: root} do
      create(root, "x.ex", "line1\nline2\nline3")

      assert {:ok, _} = Files.edit(root, "x.ex", "line1\nline2", "replaced")
      assert {:ok, "replaced\nline3"} = Files.read(root, "x.ex")
    end

    test "editing a missing file returns the file error, not the target error", %{root: root} do
      assert {:error, :file_missing} = Files.edit(root, "does-not-exist.ex", "a", "b")
    end
  end

  describe "list" do
    test "lists the project files in deterministic order", %{root: root} do
      create(root, "lib/zeta.ex", "z")
      create(root, "lib/alpha.ex", "a")
      create(root, "readme.md", "r")

      assert {:ok, files} = Files.list(root)

      assert files == Enum.sort(files)
      assert "lib/alpha.ex" in files
      assert "lib/zeta.ex" in files
      assert "readme.md" in files
    end

    test "two consecutive listings give the same order", %{root: root} do
      for n <- 1..10, do: create(root, "lib/a#{n}.ex", "x")

      {:ok, one} = Files.list(root)
      {:ok, other} = Files.list(root)

      assert one == other
    end

    test "accepts a pattern", %{root: root} do
      create(root, "lib/x.ex", "x")
      create(root, "readme.md", "r")

      assert {:ok, ["lib/x.ex"]} = Files.list(root, "lib/*.ex")
    end

    test "lists files only, not directories", %{root: root} do
      create(root, "lib/sub/x.ex", "x")

      {:ok, files} = Files.list(root)
      refute "lib/sub" in files
    end
  end

  describe "search" do
    test "finds the text with path and line number", %{root: root} do
      create(root, "lib/x.ex", "first\nsecond with target\nthird")

      assert {:ok, [{"lib/x.ex", 2, "second with target"}]} = Files.search(root, "target")
    end

    test "finds in several files", %{root: root} do
      create(root, "lib/a.ex", "has target")
      create(root, "lib/b.ex", "also has target")

      {:ok, matches} = Files.search(root, "target")
      assert length(matches) == 2
    end

    test "missing text returns an empty list, not an error", %{root: root} do
      create(root, "lib/x.ex", "nothing here")
      assert {:ok, []} = Files.search(root, "nonexistent")
    end

    test "search is literal, not a regex", %{root: root} do
      create(root, "lib/x.ex", "cost * 2")

      assert {:ok, [{_, _, "cost * 2"}]} = Files.search(root, "cost * 2")
      assert {:ok, []} = Files.search(root, ".*")
    end

    test "respects the match limit", %{root: root} do
      create(root, "lib/x.ex", Enum.map_join(1..100, "\n", fn _ -> "target" end))

      {:ok, matches} = Files.search(root, "target", limit: 5)
      assert length(matches) == 5
    end
  end
end

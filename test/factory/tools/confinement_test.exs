defmodule Factory.Tools.ConfinementTest do
  @moduledoc """
  One way of escaping per test: the proof that confinement is a property of the code, not a
  request in the prompt.
  """

  use ExUnit.Case, async: true

  alias Factory.Tools.Confinement

  # Under `_build`, NOT `System.tmp_dir!/0`: on Windows the temp dir comes in 8.3 short form
  # while `:file.read_link_all/1` returns the long form, and the "link pointing inside" test
  # would fail because of that documented limitation instead of what it wants to prove.
  defp temp_base do
    Path.join([File.cwd!(), "_build", "test", "tmp"])
  end

  setup do
    base = Path.join(temp_base(), "conf-#{System.unique_integer([:positive])}")
    root = Path.join(base, "project")
    outside = Path.join(base, "outside")

    File.mkdir_p!(Path.join(root, "sub"))
    File.mkdir_p!(outside)
    File.write!(Path.join(root, "inside.txt"), "inside")
    File.write!(Path.join(outside, "secret.txt"), "secret")

    on_exit(fn -> remove_tree(base) end)
    {:ok, root: root, outside: outside, base: base}
  end

  # `File.rm_rf/1` does not recognize a Windows junction as a link and can leave the tree on
  # disk, where a later run with a reused number collides with it. `rmdir /s /q` removes the
  # junction itself without following it.
  defp remove_tree(path) do
    if match?({:win32, _}, :os.type()) do
      System.cmd("cmd", ["/c", "rmdir", "/s", "/q", String.replace(path, "/", "\\")],
        stderr_to_stdout: true
      )
    else
      File.rm_rf(path)
    end
  end

  describe "what passes" do
    test "a simple relative path", %{root: root} do
      assert {:ok, absolute} = Confinement.resolve(root, "inside.txt")
      assert String.ends_with?(String.replace(absolute, "\\", "/"), "project/inside.txt")
    end

    test "a path in a subdirectory", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, "sub/file.ex")
    end

    test "a file that does NOT exist yet (write creates it)", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, "new/path/not-yet.ex")
    end

    test "the root itself", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, ".")
    end

    test "a traversal that comes back inside", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, "sub/../inside.txt")
    end

    test "an absolute path pointing INSIDE", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, Path.join(root, "inside.txt"))
    end
  end

  describe "escape 1: absolute path outside" do
    test "refuses an absolute system path", %{root: root} do
      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "C:/Windows/System32/drivers/etc/hosts")
    end

    test "refuses a Unix-style absolute path", %{root: root} do
      assert {:error, :outside_confinement} = Confinement.resolve(root, "/etc/passwd")
    end

    test "refuses an absolute path to the project's sibling", %{root: root, outside: outside} do
      assert {:error, :outside_confinement} =
               Confinement.resolve(root, Path.join(outside, "secret.txt"))
    end
  end

  describe "escape 2: traversal" do
    test "refuses ../ leaving the root", %{root: root} do
      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "../outside/secret.txt")
    end

    test "refuses a deep traversal", %{root: root} do
      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "../../../../../../Windows/win.ini")
    end

    test "refuses a traversal that only shows AFTER normalizing", %{root: root} do
      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "sub/../../outside/secret.txt")
    end

    test "refuses a traversal with backslashes", %{root: root} do
      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "..\\outside\\secret.txt")
    end

    test "a sibling directory with a PREFIX name does not pass", %{base: base} do
      # `/project-other` starts with `/project`; without the slash in the prefix check it
      # would pass as "under" the root.
      root = Path.join(base, "project")
      neighbour = Path.join(base, "project-other")
      File.mkdir_p!(neighbour)

      assert {:error, :outside_confinement} =
               Confinement.resolve(root, Path.join(neighbour, "x.txt"))
    end
  end

  describe "escape 3: link pointing outside" do
    # `File.ln_s/2` returns `:eperm` on Windows without admin rights, but a directory junction
    # (`mklink /J`) can be created by any user and resolves the same way.
    defp create_link(target, link) do
      case File.ln_s(target, link) do
        :ok ->
          :ok

        {:error, _} ->
          {_output, code} =
            System.cmd(
              "cmd",
              [
                "/c",
                "mklink",
                "/J",
                String.replace(link, "/", "\\"),
                String.replace(target, "/", "\\")
              ],
              stderr_to_stdout: true
            )

          if code == 0, do: :ok, else: {:error, :no_link}
      end
    end

    test "refuses a link whose TARGET is outside", %{root: root, outside: outside} do
      link = Path.join(root, "shortcut")

      assert :ok = create_link(outside, link),
             "without creating the link this test proves nothing"

      # The textual path is ENTIRELY inside the root; only resolving the real target shows
      # the escape.
      assert {:error, :outside_confinement} = Confinement.resolve(root, "shortcut/secret.txt")
    end

    test "a link pointing INSIDE still passes", %{root: root} do
      target = Path.join(root, "sub")
      link = Path.join(root, "inner-shortcut")

      assert :ok = create_link(target, link)
      assert {:ok, _} = Confinement.resolve(root, "inner-shortcut/file.txt")
    end

    test "the resolver follows links even when the target does not exist", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, "sub/new/file.txt")
    end
  end

  describe "escape 4: UNC path" do
    test "refuses \\\\server\\share", %{root: root} do
      assert {:error, :unc_path} = Confinement.resolve(root, "\\\\server\\share\\x.txt")
    end

    test "refuses //server/share", %{root: root} do
      assert {:error, :unc_path} = Confinement.resolve(root, "//server/share/x.txt")
    end
  end

  describe "escape 5: device name" do
    test "refuses every reserved device", %{root: root} do
      for name <- ~w[CON PRN AUX NUL COM1 LPT1] do
        assert {:error, :device} = Confinement.resolve(root, name),
               "#{name} had to be refused: it is a device, not a file"
      end
    end

    test "refuses a device WITH AN EXTENSION", %{root: root} do
      assert {:error, :device} = Confinement.resolve(root, "nul.txt")
    end

    test "refuses a device in a subdirectory", %{root: root} do
      assert {:error, :device} = Confinement.resolve(root, "sub/con")
    end

    test "refuses in any case", %{root: root} do
      assert {:error, :device} = Confinement.resolve(root, "NuL")
    end

    test "a name that only STARTS with a device name passes", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, "console.ex")
      assert {:ok, _} = Confinement.resolve(root, "nullable.txt")
    end
  end

  describe "upper and lower case" do
    test "the comparison is case-insensitive on Windows", %{root: root, outside: outside} do
      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "..\\OUTSIDE\\SECRET.TXT")

      assert {:error, :outside_confinement} =
               Confinement.resolve(root, String.upcase(Path.join(outside, "secret.txt")))
    end

    test "the same directory in upper case stays INSIDE", %{root: root} do
      if match?({:win32, _}, :os.type()) do
        assert {:ok, _} = Confinement.resolve(root, String.upcase("inside.txt"))
      end
    end

    test "normalize makes paths comparable" do
      # Backslash is a separator on every platform; case follows the file system. Both
      # branches assert.
      if match?({:win32, _}, :os.type()) do
        assert Confinement.normalize("C:\\Folder\\Sub\\") ==
                 Confinement.normalize("C:/folder/sub")
      else
        # On Linux `Folder` and `folder` are DIFFERENT directories: the slash is normalized,
        # the case is preserved.
        assert Confinement.normalize("C:\\Folder\\Sub\\") == "C:/Folder/Sub"

        refute Confinement.normalize("C:\\Folder\\Sub\\") ==
                 Confinement.normalize("C:/folder/sub")
      end
    end
  end

  describe "malformed input" do
    test "a non-string argument is refused", %{root: root} do
      assert {:error, :invalid_path} = Confinement.resolve(root, nil)
      assert {:error, :invalid_path} = Confinement.resolve(root, 42)
    end

    test "an empty string resolves to the root itself", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, "")
    end
  end

  describe "new directories and the file system root" do
    test "two missing directory levels: accepted, and returned ABSOLUTE", %{root: root} do
      assert {:ok, absolute} = Confinement.resolve(root, "level1/level2/file.txt")
      assert Path.type(absolute) == :absolute
      assert absolute == Path.join([Path.expand(root), "level1", "level2", "file.txt"])
    end

    test "normalize keeps the file system root" do
      assert Confinement.normalize("/") == "/"
    end

    test "normalize is unchanged for anything that is NOT the root" do
      assert Confinement.normalize("") == ""
      assert Confinement.normalize("a/b") == "a/b"
      assert Confinement.normalize("a/b/") == "a/b"
      assert Confinement.normalize("/home/x/") == "/home/x"
      assert Confinement.normalize("/home/x") == "/home/x"
    end
  end

  describe "escape 6: new directory AFTER a link" do
    test "a link outside followed by directories that do not exist yet is refused",
         %{root: root, outside: outside} do
      # `write` does `mkdir_p` through the link, so the file would be born outside.
      link = Path.join(root, "shortcut-outside")
      assert :ok = create_link(outside, link)

      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "shortcut-outside/new/more/file.txt")
    end

    test "a link inside followed by new directories still passes", %{root: root} do
      link = Path.join(root, "shortcut-sub")
      assert :ok = create_link(Path.join(root, "sub"), link)

      assert {:ok, _} = Confinement.resolve(root, "shortcut-sub/new/more/file.txt")
    end

    @tag timeout: 10_000
    test "a link cycle is refused without hanging the resolution", %{root: root} do
      a = Path.join(root, "cycle-a")
      b = Path.join(root, "cycle-b")
      assert :ok = create_link(b, a)
      assert :ok = create_link(a, b)

      assert {:error, :outside_confinement} = Confinement.resolve(root, "cycle-a/x/y.txt")
      assert {:error, :outside_confinement} = Confinement.resolve(root, "cycle-a")
    end
  end

  describe "path semantics per OS" do
    test "backslash is a separator: resolve returns the SAME form it judged", %{root: root} do
      assert {:ok, absolute} = Confinement.resolve(root, "sub\\new.txt")
      assert absolute == Path.expand(Path.join(root, "sub/new.txt"))
      refute String.contains?(absolute, "\\")
    end

    test "the root written in ANOTHER case: same directory on Windows, sibling OUTSIDE on Linux",
         %{root: root, base: base} do
      other_case = Path.join(base, "PROJECT")

      if match?({:win32, _}, :os.type()) do
        assert {:ok, _} = Confinement.resolve(root, Path.join(other_case, "inside.txt"))
      else
        File.mkdir_p!(other_case)
        File.write!(Path.join(other_case, "secret.txt"), "secret")

        assert {:error, :outside_confinement} =
                 Confinement.resolve(root, Path.join(other_case, "secret.txt"))

        assert {:error, :outside_confinement} =
                 Confinement.resolve(root, "..\\PROJECT\\secret.txt")
      end
    end
  end

  # A RELATIVE link target needs a real symbolic link: a junction only accepts absolute
  # targets. Without the privilege for `File.ln_s/2` the agent cannot create such a link
  # either, so the tests below are SKIPPED with the reason.
  @no_relative_link (fn ->
                       probe =
                         Path.join([
                           File.cwd!(),
                           "_build",
                           "test",
                           "tmp",
                           "probe-ln-#{System.unique_integer([:positive])}"
                         ])

                       File.mkdir_p!(Path.dirname(probe))
                       result = File.ln_s("relative-target", probe)
                       File.rm(probe)

                       if result != :ok,
                         do: "no privilege for symbolic links: #{inspect(result)}"
                     end).()

  describe "escape 7: a RELATIVE link target is resolved in the REAL directory" do
    @describetag skip: @no_relative_link

    test "relative link AFTER a link outside: `../..` climbs from the real directory",
         %{root: root, outside: outside, base: base} do
      # Textually `l` lives in `project/d1/d2/shortcut/` and `../../x` is inside; for the
      # kernel `l` lives in `outside/target/` and `../../x` is `<base>/x`, outside.
      target = Path.join(outside, "target")
      x = Path.join(base, "x")
      File.mkdir_p!(target)
      File.mkdir_p!(x)
      File.write!(Path.join(x, "secret.txt"), "secret of x")
      File.mkdir_p!(Path.join(root, "d1/d2"))

      assert :ok = create_link(target, Path.join(root, "d1/d2/shortcut"))
      assert :ok = File.ln_s("../../x", Path.join(target, "l"))

      # The OS really leaves the root: this is what the confinement must see.
      assert File.read!(Path.join(root, "d1/d2/shortcut/l/secret.txt")) == "secret of x"

      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "d1/d2/shortcut/l/secret.txt")

      assert {:error, :outside_confinement} = Confinement.resolve(root, "d1/d2/shortcut/l")

      assert {:error, :outside_confinement} =
               Confinement.resolve(root, "d1/d2/shortcut/l/new/file.txt")
    end

    test "`..` INSIDE the relative target, after a link, also climbs from the real directory",
         %{root: root, outside: outside} do
      # `l -> shortcut/../z` with `shortcut -> outside/target`: for the kernel `l` is
      # `outside/z`.
      target = Path.join(outside, "target")
      z = Path.join(outside, "z")
      File.mkdir_p!(target)
      File.mkdir_p!(z)
      File.write!(Path.join(z, "secret.txt"), "secret of z")

      assert :ok = create_link(target, Path.join(root, "shortcut"))
      assert :ok = File.ln_s("shortcut/../z", Path.join(root, "l"))

      assert File.read!(Path.join(root, "l/secret.txt")) == "secret of z"
      assert {:error, :outside_confinement} = Confinement.resolve(root, "l/secret.txt")
    end

    test "a relative link that stays INSIDE through the real directory is still accepted",
         %{root: root} do
      # Includes the case the TEXT would send outside but the real directory keeps inside:
      # `deep-shortcut -> sub/a/b` and `sub/a/b/back -> ../../target` lands in `sub/target`.
      File.write!(Path.join(root, "sub/here.txt"), "here")
      assert :ok = File.ln_s("sub", Path.join(root, "rel"))
      assert {:ok, _} = Confinement.resolve(root, "rel/here.txt")
      assert {:ok, _} = Confinement.resolve(root, "rel/new/file.txt")

      deep = Path.join(root, "sub/a/b")
      File.mkdir_p!(deep)
      File.mkdir_p!(Path.join(root, "sub/target"))
      File.write!(Path.join(root, "sub/target/file.txt"), "in target")
      assert :ok = create_link(deep, Path.join(root, "deep-shortcut"))
      assert :ok = File.ln_s("../../target", Path.join(deep, "back"))

      assert File.read!(Path.join(root, "deep-shortcut/back/file.txt")) == "in target"
      assert {:ok, _} = Confinement.resolve(root, "deep-shortcut/back/file.txt")
      assert {:ok, _} = Confinement.resolve(root, "deep-shortcut/back/new/file.txt")
    end

    @tag timeout: 10_000
    test "the 40-hop cap applies to the WHOLE resolution, not per branch", %{root: root} do
      # `n1 -> n2/n2`, ..., `n25 -> .`: resolving `n1` needs 2^24 hops. Counting per branch
      # would explore the whole tree and hang the tool call.
      tree = Path.join(root, "tree")
      File.mkdir_p!(tree)

      for k <- 1..24 do
        assert :ok = File.ln_s("n#{k + 1}/n#{k + 1}", Path.join(tree, "n#{k}"))
      end

      assert :ok = File.ln_s(".", Path.join(tree, "n25"))

      assert {:error, _} = File.read(Path.join(tree, "n1/file.txt"))
      assert {:error, :outside_confinement} = Confinement.resolve(root, "tree/n1/file.txt")
    end
  end

  describe "escape 8: UNC with MIXED slashes in the prefix" do
    # `\/server` and `/\server` are the same `//server` for Windows. `:unc_path` proves the
    # refusal happens before any disk access: only the first step of `resolve/2` produces it.

    test "the four network prefix forms are refused as UNC", %{root: root} do
      forms = ["\\/srv/share/x", "/\\srv\\share\\x", "\\\\srv\\share\\x", "//srv/share/x"]

      # A form -> result map shows WHICH form escaped.
      assert Map.new(forms, &{&1, Confinement.resolve(root, &1)}) ==
               Map.new(forms, &{&1, {:error, :unc_path}})
    end

    test "a plain Unix absolute path and a SINGLE backslash are not UNC", %{root: root} do
      assert {:ok, _} = Confinement.resolve(root, Path.join(root, "inside.txt"))

      for path <- ["/home/x/file.txt", "\\lib\\foo.ex"] do
        assert {:error, reason} = Confinement.resolve(root, path)
        refute reason == :unc_path, "#{path} became :unc_path"
      end
    end
  end
end

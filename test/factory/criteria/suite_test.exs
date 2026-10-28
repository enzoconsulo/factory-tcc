defmodule Factory.Criteria.SuiteTest do
  @moduledoc """
  The criterion nobody writes, and the detection that finds it. Each test builds a fake project
  in a temp directory containing only marker files.
  """

  use ExUnit.Case, async: true

  alias Factory.Criteria
  alias Factory.Criteria.Suite
  alias Factory.Ecosystems

  doctest Factory.Criteria.Suite

  defp project(files) do
    root = Path.join(System.tmp_dir!(), "suite-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    Enum.each(files, fn {path, content} ->
      target = Path.join(root, path)
      File.mkdir_p!(Path.dirname(target))
      File.write!(target, content)
    end)

    root
  end

  defp ci_json(command) do
    Jason.encode!(%{
      "ecosystem" => "any",
      "stages" => [
        %{"name" => "format", "command" => "mix format --check-formatted"},
        %{"name" => "tests", "command" => command}
      ]
    })
  end

  describe "marker-file detection, one test per ecosystem" do
    test "mix.exs is Elixir" do
      root = project([{"mix.exs", ""}])

      assert %{id: :elixir, test_command: "mix test"} = Ecosystems.detect(root)
      assert {:ok, "mix test", {:detected, :elixir}} = Suite.command(root)
    end

    test "package.json is Node" do
      root = project([{"package.json", "{}"}])

      assert %{id: :node} = Ecosystems.detect(root)
      assert {:ok, "npm test", {:detected, :node}} = Suite.command(root)
    end

    test "pyproject.toml is Python" do
      root = project([{"pyproject.toml", ""}])

      assert %{id: :python} = Ecosystems.detect(root)
      assert {:ok, "pytest", {:detected, :python}} = Suite.command(root)
    end

    test "Cargo.toml is Rust" do
      root = project([{"Cargo.toml", ""}])

      assert %{id: :rust} = Ecosystems.detect(root)
      assert {:ok, "cargo test", {:detected, :rust}} = Suite.command(root)
    end

    test "go.mod is Go" do
      root = project([{"go.mod", ""}])

      assert %{id: :go} = Ecosystems.detect(root)
      assert {:ok, "go test ./...", {:detected, :go}} = Suite.command(root)
    end

    test "*.csproj is .NET (the marker is an extension, not an exact name)" do
      root = project([{"Api.csproj", ""}])

      assert %{id: :dotnet} = Ecosystems.detect(root)
      assert {:ok, "dotnet test", {:detected, :dotnet}} = Suite.command(root)
    end

    test "Python is also detected by requirements.txt and setup.py" do
      for marker <- ["requirements.txt", "setup.py"] do
        root = project([{marker, ""}])
        assert %{id: :python} = Ecosystems.detect(root), "should detect by #{marker}"
      end
    end
  end

  describe "priority order" do
    test "Elixir beats Node" do
      # The factory itself is an Elixir project WITH a package.json (Phoenix assets).
      root = project([{"mix.exs", ""}, {"package.json", "{}"}])

      assert %{id: :elixir} = Ecosystems.detect(root)
    end

    test "the factory itself is detected as Elixir" do
      assert %{id: :elixir} = Ecosystems.detect(File.cwd!())
    end

    test "the catalog is in the declared order" do
      ids = Enum.map(Ecosystems.catalog(), & &1.id)

      assert ids == [:elixir, :node, :python, :rust, :go, :dotnet]
    end

    test "Node beats Python when only those two are present" do
      root = project([{"package.json", "{}"}, {"pyproject.toml", ""}])

      assert %{id: :node} = Ecosystems.detect(root)
    end
  end

  describe "ci.json beats detection" do
    test "a declaration wins over a guess" do
      root = project([{"mix.exs", ""}, {"_management/ci.json", ci_json("mix verify")}])

      assert {:ok, "mix verify", :declared} = Suite.command(root)
    end

    test "wins even when the ecosystem would not be recognised" do
      root = project([{"_management/ci.json", ci_json("./run-tests.sh")}])

      assert Ecosystems.detect(root) == nil
      assert {:ok, "./run-tests.sh", :declared} = Suite.command(root)
    end

    test "broken JSON in ci.json falls back to detection" do
      root = project([{"mix.exs", ""}, {"_management/ci.json", "{ this is not json"}])

      assert {:ok, "mix test", {:detected, :elixir}} = Suite.command(root)
    end

    test "ci.json without a tests stage falls back to detection" do
      format_only = Jason.encode!(%{"stages" => [%{"name" => "format", "command" => "x"}]})
      root = project([{"mix.exs", ""}, {"_management/ci.json", format_only}])

      assert {:ok, "mix test", {:detected, :elixir}} = Suite.command(root)
    end

    test "a tests stage with an empty command falls back to detection" do
      root = project([{"mix.exs", ""}, {"_management/ci.json", ci_json("   ")}])

      assert {:ok, "mix test", {:detected, :elixir}} = Suite.command(root)
    end

    test "ci.json without the stages key falls back to detection" do
      root =
        project([{"mix.exs", ""}, {"_management/ci.json", Jason.encode!(%{"nothing" => true})}])

      assert {:ok, "mix test", {:detected, :elixir}} = Suite.command(root)
    end
  end

  describe "a project without a recognised ecosystem does not break" do
    test "returns a named error instead of raising" do
      root = project([{"README.txt", "a project of nothing"}])

      assert Ecosystems.detect(root) == nil
      assert {:error, :no_ecosystem} = Suite.command(root)
      assert Suite.criterion(root) == nil
    end

    test "a directory that does not exist does not raise either" do
      assert Ecosystems.detect("C:/path/that/does/not/exist") == nil
      assert {:error, :no_ecosystem} = Suite.command("C:/path/that/does/not/exist")
    end

    test "append/2 returns the list unchanged" do
      root = project([{"README.txt", ""}])
      written = [%{text: "someone judges", command: nil, checked: false, implicit: false}]

      assert Suite.append(written, root) == written
    end

    test "an empty directory is not an ecosystem" do
      assert Ecosystems.detect(project([])) == nil
    end
  end

  describe "the implicit criterion" do
    test "is marked implicit and its text says where it came from" do
      root = project([{"mix.exs", ""}])
      criterion = Suite.criterion(root)

      assert criterion.implicit
      assert criterion.command == "mix test"
      assert criterion.text =~ "detected: Elixir / Mix"
      refute criterion.checked
    end

    test "when declared, the text points to the FILE, not the guess" do
      root = project([{"mix.exs", ""}, {"_management/ci.json", ci_json("mix verify")}])

      assert Suite.criterion(root).text =~ "declared in _management/ci.json"
    end

    test "goes to the END of the list" do
      root = project([{"mix.exs", ""}])
      written = [%{text: "first", command: nil, checked: false, implicit: false}]

      assert [%{text: "first"}, %{implicit: true}] = Suite.append(written, root)
    end
  end

  describe "includes_suite: a command that already runs the suite skips the implicit one" do
    test "a criterion with a command listed in includes_suite skips the implicit one" do
      root =
        project([
          {"mix.exs", ""},
          {"_management/ci.json", Jason.encode!(%{"includes_suite" => ["mix factory.ci"]})}
        ])

      written = [
        %{text: "the battery", command: "mix factory.ci", checked: false, implicit: false}
      ]

      assert Suite.append(written, root) == written
    end

    test "a criterion with another command keeps the implicit one" do
      root =
        project([
          {"mix.exs", ""},
          {"_management/ci.json", Jason.encode!(%{"includes_suite" => ["mix factory.ci"]})}
        ])

      written = [
        %{text: "one file", command: "mix test test/x_test.exs", checked: false, implicit: false}
      ]

      assert [%{text: "one file"}, %{implicit: true}] = Suite.append(written, root)
    end

    test "without the field, the implicit one still goes in" do
      root = project([{"mix.exs", ""}])

      written = [
        %{text: "the battery", command: "mix factory.ci", checked: false, implicit: false}
      ]

      assert [%{text: "the battery"}, %{implicit: true}] = Suite.append(written, root)
    end

    test "a string instead of a list does not raise and keeps the implicit one" do
      root =
        project([
          {"mix.exs", ""},
          {"_management/ci.json", Jason.encode!(%{"includes_suite" => "mix factory.ci"})}
        ])

      written = [
        %{text: "the battery", command: "mix factory.ci", checked: false, implicit: false}
      ]

      assert [%{text: "the battery"}, %{implicit: true}] = Suite.append(written, root)
    end

    test "a list with a number is invalid as a whole and keeps the implicit one" do
      root =
        project([
          {"mix.exs", ""},
          {"_management/ci.json", Jason.encode!(%{"includes_suite" => ["mix factory.ci", 42]})}
        ])

      written = [
        %{text: "the battery", command: "mix factory.ci", checked: false, implicit: false}
      ]

      assert [%{text: "the battery"}, %{implicit: true}] = Suite.append(written, root)
    end

    test "broken JSON does not raise and keeps the implicit one" do
      root = project([{"mix.exs", ""}, {"_management/ci.json", "{ not json"}])

      written = [
        %{text: "the battery", command: "mix factory.ci", checked: false, implicit: false}
      ]

      assert [%{text: "the battery"}, %{implicit: true}] = Suite.append(written, root)
    end

    test "matching uses the same command_key (.exe/.bat normalised)" do
      root =
        project([
          {"mix.exs", ""},
          {"_management/ci.json", Jason.encode!(%{"includes_suite" => ["mix.bat factory.ci"]})}
        ])

      written = [
        %{text: "the battery", command: "mix factory.ci", checked: false, implicit: false}
      ]

      assert Suite.append(written, root) == written
    end

    test "a criterion without a command never skips the implicit one" do
      root =
        project([
          {"mix.exs", ""},
          {"_management/ci.json", Jason.encode!(%{"includes_suite" => ["mix factory.ci"]})}
        ])

      written = [%{text: "human judgement", command: nil, checked: false, implicit: false}]

      assert [%{text: "human judgement"}, %{implicit: true}] = Suite.append(written, root)
    end
  end

  describe "the implicit criterion in the report" do
    test "is marked [implicit]" do
      # A fake project declaring a cheap command: running the pass over the factory itself
      # would launch the suite from inside the suite.
      root = project([{"_management/ci.json", ci_json("git rev-parse --git-dir")}])

      text =
        [%{text: "written by someone", command: "git status --short", checked: false}]
        |> Suite.append(root)
        |> Criteria.run(root)
        |> Criteria.report()

      assert text =~ "written by someone"
      assert text =~ "[implicit] The project suite passes"
      refute text =~ "[implicit] written by someone"
    end

    test "a hand-written criterion does not get the mark" do
      text =
        [%{text: "written", command: "git rev-parse --git-dir", checked: false}]
        |> Criteria.run(File.cwd!())
        |> Criteria.report()

      refute text =~ "[implicit]"
    end

    test "the mark survives deduplication on the right side" do
      # The mirror inherits the verdict, not the identity.
      root = File.cwd!()
      command = "git rev-parse --git-dir"

      results =
        [
          %{text: "written", command: command, checked: false, implicit: false},
          %{text: "the suite", command: command, checked: false, implicit: true}
        ]
        |> Criteria.run(root)

      assert [%{implicit: false, mirror: false}, %{implicit: true, mirror: true}] = results
    end

    test "the implicit suite costs no extra run when the task already declares it" do
      root = File.cwd!()
      command = "git rev-parse --git-dir"

      text =
        [
          %{text: "the battery", command: command, checked: false, implicit: false},
          %{text: "the suite", command: command, checked: false, implicit: true}
        ]
        |> Criteria.run(root)
        |> Criteria.report()

      assert text =~ "same command already run above"
      assert text =~ "Proof levels: 2 executed (of 2)."
    end
  end
end

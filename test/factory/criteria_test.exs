defmodule Factory.CriteriaTest do
  @moduledoc """
  The mechanical pass: parsing, allowlist, deduplication and report. Tests that really execute
  use read-only `git`, which is fast, deterministic and present wherever the factory runs.
  """

  use ExUnit.Case, async: true

  alias Factory.Criteria
  alias Factory.Criteria.Allowlist

  doctest Factory.Criteria.Allowlist
  doctest Factory.Criteria

  @root File.cwd!()

  defp criterion(text, command \\ nil) do
    %{text: text, command: command, checked: false}
  end

  describe "allowlist — allow the known" do
    test "a listed binary passes and argv comes back already split" do
      assert {:ok, ["mix", "test"]} = Allowlist.check("mix test")
      assert {:ok, ["npm", "run", "build"]} = Allowlist.check("npm run build")
    end

    test "an unlisted binary is refused with a named reason" do
      for command <- ["curl http://x", "wget x", "rm -rf /", "powershell -c x", "bash -c x"] do
        assert {:refused, :binary_not_allowed} = Allowlist.check(command),
               "#{command} should be refused"
      end
    end

    test "the Windows extension does not change the binary" do
      assert {:ok, _} = Allowlist.check("mix.bat test")
      assert {:ok, _} = Allowlist.check("NPM.CMD test")
    end

    test "an empty or missing command is :no_command, not an invalid binary" do
      assert {:refused, :no_command} = Allowlist.check(nil)
      assert {:refused, :no_command} = Allowlist.check("")
      assert {:refused, :no_command} = Allowlist.check("   ")
    end

    test "npx is excluded" do
      # It downloads and runs code that is not in the project.
      assert {:refused, :binary_not_allowed} = Allowlist.check("npx cowsay hi")
      refute "npx" in Allowlist.binaries()
    end
  end

  describe "allowlist — git only in read-only mode" do
    test "read-only subcommands pass" do
      for subcommand <- Allowlist.git_read_only() do
        assert {:ok, _} = Allowlist.check("git #{subcommand}"),
               "git #{subcommand} should pass"
      end
    end

    test "subcommands that WRITE are refused with their own reason" do
      for subcommand <- ~w[push reset clean checkout commit rm mv] do
        assert {:refused, :git_not_read_only} = Allowlist.check("git #{subcommand}"),
               "git #{subcommand} should be refused"
      end
    end

    test "git without a subcommand is refused" do
      assert {:refused, :git_not_read_only} = Allowlist.check("git")
    end
  end

  describe "allowlist — one command, never a script" do
    test "chaining is refused" do
      for command <- ["mix test && git push", "mix test || echo x", "mix test ; rm -rf ."] do
        assert {:refused, :chaining_forbidden} = Allowlist.check(command),
               "#{command} should be refused"
      end
    end

    test "a pipe is refused" do
      assert {:refused, :chaining_forbidden} = Allowlist.check("mix test | grep ok")
    end

    test "redirection is refused" do
      assert {:refused, :chaining_forbidden} = Allowlist.check("mix test > output.txt")
      assert {:refused, :chaining_forbidden} = Allowlist.check("mix test < input.txt")
    end

    test "command substitution is refused in both forms" do
      assert {:refused, :chaining_forbidden} = Allowlist.check("mix test $(whoami)")
      assert {:refused, :chaining_forbidden} = Allowlist.check("mix test `whoami`")
    end

    test "a newline is refused: it is disguised chaining" do
      assert {:refused, :chaining_forbidden} = Allowlist.check("mix test\ngit push")
    end

    test "the chaining refusal comes BEFORE the binary check" do
      assert {:refused, :chaining_forbidden} = Allowlist.check("mix test && curl x")
    end
  end

  describe "parsing criteria" do
    test "reads text, command and checkbox" do
      section = """
      - [ ] The suite passes.
            `verify: mix test`
      - [x] The format is right.
            `verify: mix format --check-formatted`
      """

      assert [first, second] = Criteria.parse(section)
      assert first.text == "The suite passes."
      assert first.command == "mix test"
      refute first.checked
      assert second.checked
      assert second.command == "mix format --check-formatted"
    end

    test "a criterion without a command is normal, not a defect" do
      assert [%{command: nil, text: "The report explains the decision."}] =
               Criteria.parse("- [ ] The report explains the decision.")
    end

    test "reads the indented CONTINUATION" do
      section = """
      - [ ] The game sends the current player a
            notification with the available options.
            `verify: mix test test/game_test.exs`
      """

      assert [criterion] = Criteria.parse(section)
      assert criterion.text =~ "notification with the available options"
      assert criterion.command == "mix test test/game_test.exs"
    end

    test "the continuation stops at the next criterion" do
      section = """
      - [ ] First
            continuation of the first
      - [ ] Second
      """

      assert [first, second] = Criteria.parse(section)
      assert first.text == "First continuation of the first"
      assert second.text == "Second"
    end

    test "the continuation stops when the indentation ends" do
      section = """
      - [ ] First
            continuation
      loose text that is not a continuation
      """

      assert [criterion] = Criteria.parse(section)
      refute criterion.text =~ "loose text"
    end

    test "an empty or missing section returns an empty list without raising" do
      assert Criteria.parse("") == []
      assert Criteria.parse(nil) == []
      assert Criteria.parse("## Acceptance criteria\n\nnothing here") == []
    end

    test "a malformed line does not break parsing of the others" do
      section = """
      - [ ] Valid `verify: mix test`
      - [] no space in the checkbox
      - [ ] Another valid
      """

      texts = section |> Criteria.parse() |> Enum.map(& &1.text)
      assert texts == ["Valid", "Another valid"]
    end
  end

  describe "execution — the command really runs" do
    test "a passing command becomes :passed" do
      assert [%{state: :passed}] =
               Criteria.run([criterion("repo exists", "git rev-parse --git-dir")], @root)
    end

    test "a failing command becomes :failed with its output attached" do
      [result] =
        Criteria.run([criterion("object exists", "git cat-file -t 0000000000")], @root)

      assert result.state == :failed
      assert result.output != ""
    end

    test "a criterion without a command does not run and keeps the reason" do
      assert [%{state: :not_run, refusal: :no_command}] =
               Criteria.run([criterion("someone judges this")], @root)
    end

    test "a refused command does not run, and the reason differs from no-command" do
      assert [%{state: :not_run, refusal: :binary_not_allowed}] =
               Criteria.run([criterion("downloads things", "curl http://x")], @root)
    end

    test "the output is truncated" do
      [result] =
        Criteria.run([criterion("huge log", "git log --format=%H%n%B")], @root)

      assert byte_size(result.output) <= 2_100
    end
  end

  describe "retry when the output is lost (FAB-403.2)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "lost-output-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    defp write_fake(dir, js) do
      path = Path.join(dir, "fake.js")
      File.write!(path, js)
      path
    end

    test "1st call fails printing nothing, 2nd prints: keeps the 2nd output", %{dir: dir} do
      counter = Path.join(dir, "counter")

      path =
        write_fake(dir, """
        const fs = require('fs');
        const counter = process.argv[2];
        let n = 0;
        try { n = parseInt(fs.readFileSync(counter, 'utf8'), 10) || 0; } catch (e) {}
        fs.writeFileSync(counter, String(n + 1));
        if (n === 0) { process.exit(1); }
        console.log('unrecognized argument: --x');
        process.exit(1);
        """)

      assert [result] = Criteria.run([criterion("runs the fake", "node #{path} #{counter}")], dir)

      assert result.rerun
      assert result.output =~ "unrecognized argument"
      assert File.read!(counter) == "2"
    end

    test "a failure WITH output on the 1st call is not rerun", %{dir: dir} do
      counter = Path.join(dir, "counter")

      path =
        write_fake(dir, """
        const fs = require('fs');
        const counter = process.argv[2];
        let n = 0;
        try { n = parseInt(fs.readFileSync(counter, 'utf8'), 10) || 0; } catch (e) {}
        fs.writeFileSync(counter, String(n + 1));
        console.log('a real failure, with text');
        process.exit(1);
        """)

      assert [result] = Criteria.run([criterion("runs the fake", "node #{path} #{counter}")], dir)

      refute result.rerun
      assert result.output =~ "a real failure"
      assert File.read!(counter) == "1"
    end
  end

  describe "deduplication within a batch" do
    test "two criteria with the same command run ONCE" do
      criteria = [
        criterion("first", "git rev-parse --git-dir"),
        criterion("second", "git rev-parse --git-dir")
      ]

      assert [first, second] = Criteria.run(criteria, @root)

      refute first.mirror
      assert second.mirror
      assert second.state == first.state
      # The verdict is inherited; the criterion's text is not.
      assert second.text == "second"
    end

    test "different commands do not mirror each other" do
      criteria = [
        criterion("one", "git rev-parse --git-dir"),
        criterion("two", "git status --short")
      ]

      assert [%{mirror: false}, %{mirror: false}] = Criteria.run(criteria, @root)
    end

    test "the key normalises the extension and the test-script forms" do
      assert Criteria.command_key(["npm", "run", "test"]) == "npm test"
      assert Criteria.command_key(["npm", "t"]) == "npm test"
      assert Criteria.command_key(["yarn", "run", "lint"]) == "yarn lint"
      assert Criteria.command_key(["MIX.EXE", "test"]) == "mix test"
    end

    test "the key is CONSERVATIVE: when in doubt, run" do
      refute Criteria.command_key(["mix", "test"]) ==
               Criteria.command_key(["mix", "test", "test/"])

      # `npm run` only shrinks with exactly one script; with arguments it is left alone.
      assert Criteria.command_key(["npm", "run", "test", "--", "-w"]) ==
               "npm run test -- -w"
    end
  end

  describe "the report" do
    test "every criterion is labelled and the Proof levels line closes it" do
      criteria = [
        criterion("the suite passes", "git rev-parse --git-dir"),
        criterion("someone judges this")
      ]

      text = criteria |> Criteria.run(@root) |> Criteria.report()

      assert text =~ "### Mechanical pass (no model)"
      assert text =~ "- [executed] the suite passes"
      assert text =~ "- [judged] someone judges this"
      assert text =~ "Proof levels: 1 executed, 1 judged (of 2)."
    end

    test "the verdict is in bold" do
      text =
        [criterion("passes", "git rev-parse --git-dir")]
        |> Criteria.run(@root)
        |> Criteria.report()

      assert text =~ "**PASSED**"
    end

    test "the output of a failure goes in a code block" do
      text =
        [criterion("fails", "git cat-file -t 0000000000")]
        |> Criteria.run(@root)
        |> Criteria.report()

      assert text =~ "**FAILED**"
      assert text =~ "```"
    end

    test "a mirror is announced and does NOT repeat the output" do
      text =
        [
          criterion("one", "git cat-file -t 0000000000"),
          criterion("two", "git cat-file -t 0000000000")
        ]
        |> Criteria.run(@root)
        |> Criteria.report()

      assert text =~ "same command already run above"
      assert length(String.split(text, "```")) == 3
    end

    test "the refusal reason appears and differs from no-command" do
      text =
        [criterion("downloads", "curl http://x"), criterion("judges")]
        |> Criteria.run(@root)
        |> Criteria.report()

      assert text =~ "command refused: binary_not_allowed"
      assert text =~ "no command declared"
    end

    test "accepts [inspected], which comes from the VERIFIER" do
      from_verifier = %{
        text: "the screen shows the board",
        command: nil,
        state: :inspected,
        refusal: nil,
        output: "checked on the screenshot in _management/evidence/",
        mirror: false
      }

      text = Criteria.report([from_verifier])

      assert text =~ "- [inspected] the screen shows the board"
      assert text =~ "Proof levels: 1 inspected (of 1)."
    end

    test "a level with ZERO is left out of the line" do
      text =
        [criterion("passes", "git rev-parse --git-dir")]
        |> Criteria.run(@root)
        |> Criteria.report()

      refute text =~ "0 inspected"
      refute text =~ "0 judged"
      assert text =~ "Proof levels: 1 executed (of 1)."
    end

    test "an empty list returns empty text, not an orphan heading" do
      assert Criteria.report([]) == ""
    end
  end

  describe "what the pass decides" do
    test "failed? is true only when a command REALLY failed" do
      passed = Criteria.run([criterion("a", "git rev-parse --git-dir")], @root)
      failed = Criteria.run([criterion("b", "git cat-file -t 0000000000")], @root)
      judged = Criteria.run([criterion("c")], @root)
      refused = Criteria.run([criterion("d", "curl x")], @root)

      refute Criteria.failed?(passed)
      assert Criteria.failed?(failed)
      refute Criteria.failed?(judged)

      # A refused command is a planning defect and does NOT fail the task.
      refute Criteria.failed?(refused)
    end

    test "refused/1 lists PLANNING defects, without the no-command ones" do
      results =
        Criteria.run(
          [criterion("a", "curl x"), criterion("b"), criterion("c", "git push")],
          @root
        )

      assert [%{refusal: :binary_not_allowed}, %{refusal: :git_not_read_only}] =
               Criteria.refused(results)
    end

    test "passing the mechanical pass does NOT approve the task" do
      # There is deliberately no `approved?` function.
      refute function_exported?(Criteria, :approved?, 1)
    end
  end
end
